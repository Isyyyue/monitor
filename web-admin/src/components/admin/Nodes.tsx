import { CalendarClock, Check, ChevronDown, Copy, Download, Layers, Pencil, Plus, Server, Trash2 } from "lucide-react"
import { memo, useEffect, useId, useRef, useState } from "react"
import { toast } from "sonner"

import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import { Card } from "@/components/ui/card"
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from "@/components/ui/dialog"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { Popover, PopoverAnchor, PopoverContent } from "@/components/ui/popover"
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select"
import { Switch } from "@/components/ui/switch"
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table"
import { Tooltip, TooltipContent, TooltipTrigger } from "@/components/ui/tooltip"
import { api, badIfaceName, changes, currentIface, GIB, ifaceChoice, ifaceSpec, inGroup, plainEntry, provisioningSite, shortAddress, trafficCorrection, type IfaceChoice, type Node, type Source } from "@/lib/api"
import { bytes, cycleMonths, FOREVER, money, uptime } from "@/lib/format"
import { installScriptCommand } from "@/lib/install-command"
import { type Settings, CertificateOption, ConfirmDialog, copy, DragHandle, Field, GroupFilter, NodePicker, NodeSearch, OptionRow, searchNodes, useDragOrder, useGroupFilter, useSettings } from "./shared"


// Counters the panel can correct after migration or an accounting error.
const TRAFFIC_FIELDS = [
  ["total_rx", "累计下行"],
  ["total_tx", "累计上行"],
  ["month_rx", "本月下行"],
  ["month_tx", "本月上行"],
] as const

const TRAFFIC_MODES: Record<string, string> = {
  sum: "上下行相加",
  max: "取较大值",
  up: "仅上行",
  down: "仅下行",
}


const SOURCES: Record<Source, string> = {
  manual: "手动填写",
  interface: "网卡地址",
  exit: "hub 看到的出口，不在节点网卡上（NAT 或代理）",
  connection: "hub 看到的连接地址",
}


// The address a node is reached by, one per family, each click-to-copy: pasting
// one into an ssh command is why they are shown. Where each came from is in the
// tooltip, keeping the column to addresses alone.
//
// Drawn again only when the addresses change. The table re-renders on every
// push, and redrawing a tooltip per address would raise the panel's script time
// at a hundred nodes from 66 to 128 ms a second.
const Addresses = memo(
  function Addresses({ list }: { list: NonNullable<Node["addresses"]> }) {
    if (!list.length) return <span className="text-sm text-muted-foreground">—</span>
    return (
      // As wide as the longer address, so both tooltips open from one right
      // edge and the one for a short IPv4 does not cover the IPv6 below it.
      <div className="grid w-fit gap-y-0.5">
        {list.map(({ address, source }) => (
          // Beside the addresses rather than under one, where it would cover
          // the other; and gone once the pointer leaves it.
          <Tooltip key={address} disableHoverableContent>
            <TooltipTrigger asChild>
              <button
                type="button"
                // The toast names what was copied: a tap shows no tooltip, and
                // the cell may show the address shortened.
                onClick={() => copy(address, `已复制 ${address}`)}
                aria-label={`复制 ${address}`}
                className="tnum group inline-flex items-center gap-1 text-sm hover:text-foreground"
              >
                {shortAddress(address)}
                <Copy className="size-3 shrink-0 opacity-0 transition-opacity group-hover:opacity-100" />
              </button>
            </TooltipTrigger>
            <TooltipContent side="right" sideOffset={6} className="max-w-xs">
              <div className="tnum">{address}</div>
              <div className="opacity-70">{SOURCES[source]}，点击复制</div>
            </TooltipContent>
          </Tooltip>
        ))}
      </div>
    )
  },
  // Rows arrive as fresh objects on every push, so the list is compared by value.
  (a, b) => JSON.stringify(a.list) === JSON.stringify(b.list),
)


// Every command the panel hands out. break-all because a token has no spaces to
// wrap at.
function Command({ className = "", children }: { className?: string; children: React.ReactNode }) {
  return (
    <pre className={`overflow-auto whitespace-pre-wrap break-all rounded-lg border bg-muted/40 p-3 text-xs leading-relaxed select-all ${className}`}>
      {children}
    </pre>
  )
}


// Under every command a plaintext hub hands out, and nothing at all otherwise.
// The token in the command, and the agent the node then downloads and runs as
// root, both cross the network unverified -- which is what naming a plaintext
// --site accepted. Said where the command is copied, since that is the moment it
// matters.
function PlaintextNote({ site }: { site: string }) {
  if (!plainEntry(site)) return null
  return (
    <p className="text-xs leading-relaxed text-destructive">
      面板没有域名，这条命令和它下载的 agent 都不加密：链路上谁抓到，谁就能接管这台节点。
    </p>
  )
}


// Free text, with the groups already in use offered, so a group is picked
// rather than retyped, where a typo would start a second one. A list of its own
// rather than a <datalist>: Chrome draws that as a tooltip and filters it by the
// text already in the box, so a grouped node was offered only its own group.
// The whole list shows on opening; typing narrows it without highlighting, so
// Enter keeps a new name that merely prefixes an existing one.
function GroupInput({ nodes, value, onChange }: {
  nodes: Pick<Node, "group">[]
  value: string
  onChange: (value: string) => void
}) {
  const id = useId()
  const [open, setOpen] = useState(false)
  const [typed, setTyped] = useState(false)
  const [active, setActive] = useState(0)
  const input = useRef<HTMLInputElement>(null)
  const counts = new Map<string, number>()
  for (const n of nodes) if (n.group) counts.set(n.group, (counts.get(n.group) ?? 0) + 1)
  const name = value.trim()
  const query = typed ? name.toLowerCase() : ""
  const matches = [...counts.keys()].filter((g) => g.toLowerCase().includes(query))
  // "" is 未分组, offered last while the list is not being narrowed.
  const items = query ? matches : [...matches, ""]
  const fresh = typed && name !== "" && !counts.has(name)
  const shown = open && (matches.length > 0 || fresh)

  useEffect(() => {
    if (shown) document.getElementById(`${id}-${active}`)?.scrollIntoView({ block: "nearest" })
  }, [id, active, shown])

  const show = () => {
    setTyped(false)
    setActive(Math.max(0, [...counts.keys(), ""].indexOf(name)))
    setOpen(true)
  }
  const pick = (group: string) => {
    onChange(group)
    setTyped(false)
    setOpen(false)
  }
  const onKeyDown = (e: React.KeyboardEvent) => {
    if (e.key === "ArrowDown" || e.key === "ArrowUp") {
      e.preventDefault()
      if (!shown) return show()
      if (!items.length) return
      const down = e.key === "ArrowDown"
      setActive((i) => (i < 0 ? (down ? 0 : items.length - 1) : (i + (down ? 1 : -1) + items.length) % items.length))
    } else if (e.key === "Enter" && shown) {
      e.preventDefault()
      if (items[active] !== undefined) pick(items[active])
      else setOpen(false)
    }
  }

  if (!counts.size) {
    return <Input maxLength={13} value={value} onChange={(e) => onChange(e.target.value)} placeholder="未分组" />
  }
  return (
    <Popover open={shown} onOpenChange={setOpen}>
      <PopoverAnchor asChild>
        <div className="relative">
          <Input
            ref={input}
            role="combobox"
            aria-expanded={shown}
            aria-controls={id}
            aria-autocomplete="list"
            aria-activedescendant={shown && items[active] !== undefined ? `${id}-${active}` : undefined}
            maxLength={13}
            value={value}
            placeholder="未分组"
            className="pr-9"
            onChange={(e) => {
              onChange(e.target.value)
              setTyped(true)
              setActive(-1)
              setOpen(true)
            }}
            onClick={show}
            onKeyDown={onKeyDown}
          />
          {/* Not a tab stop, and keeps the focus in the box it opens a list for. */}
          <button
            type="button"
            tabIndex={-1}
            aria-label="选择分组"
            className="absolute inset-y-0 right-0 flex w-9 items-center justify-center text-muted-foreground"
            onMouseDown={(e) => {
              e.preventDefault()
              if (shown) return setOpen(false)
              input.current?.focus()
              show()
            }}
          >
            <ChevronDown className={`size-4 opacity-50 transition-transform ${shown ? "rotate-180" : ""}`} />
          </button>
        </div>
      </PopoverAnchor>
      <PopoverContent
        align="start"
        className="w-(--radix-popover-trigger-width) p-1"
        onOpenAutoFocus={(e) => e.preventDefault()}
        onCloseAutoFocus={(e) => e.preventDefault()}
        // The box and its button sit outside the list; pressing them is not a dismissal.
        onInteractOutside={(e) => input.current?.parentElement?.contains(e.target as Element) && e.preventDefault()}
        onMouseDown={(e) => e.preventDefault()}
      >
        <div role="listbox" id={id} aria-label="已有分组" className="max-h-60 overflow-y-auto">
          {items.map((group, i) => (
            <div key={group || "\0"}>
              {group === "" && <div className="my-1 h-px bg-border" />}
              <div
                id={`${id}-${i}`}
                role="option"
                aria-selected={group === name}
                onMouseEnter={() => setActive(i)}
                onClick={() => pick(group)}
                className={`relative flex cursor-default items-center gap-2 rounded-sm py-1.5 pr-8 pl-2 text-sm select-none ${i === active ? "bg-accent text-accent-foreground" : ""}`}
              >
                <span className={`truncate ${group ? "" : "text-muted-foreground"}`}>{group || "未分组"}</span>
                {group && <span className="tnum ml-auto shrink-0 text-xs text-muted-foreground">{counts.get(group)} 台</span>}
                {group === name && <Check className="absolute right-2 size-4" />}
              </div>
            </div>
          ))}
          {fresh && <p className="px-2 py-1.5 text-xs text-muted-foreground">新分组「{name}」，保存后生效</p>}
        </div>
      </PopoverContent>
    </Popover>
  )
}


// Puts the nodes ticked here into one group, or, with the name left empty, out
// of any. Renaming or dissolving a group is the same act: filter the picker to
// it, tick all, then type the new name or clear it. One request, applied to all
// of them or none.
function GroupDialog({ nodes, onClose, onSaved }: { nodes: Node[]; onClose: () => void; onSaved: () => void }) {
  const [name, setName] = useState("")
  const [chosen, setChosen] = useState<Set<number>>(new Set())
  const [saving, setSaving] = useState(false)
  const group = name.trim()
  // Counted against the live list, so a node deleted meanwhile is not sent.
  const ids = nodes.filter((n) => chosen.has(n.id)).map((n) => n.id)
  const pick = (list: Node[], on: boolean) =>
    setChosen((old) => {
      const next = new Set(old)
      for (const n of list) {
        if (on) next.add(n.id)
        else next.delete(n.id)
      }
      return next
    })

  async function save() {
    setSaving(true)
    try {
      await api("/nodes/batch", { method: "PUT", body: JSON.stringify({ ids, patch: { group } }) })
      toast.success(group ? `已把 ${ids.length} 台设为「${group}」` : `已把 ${ids.length} 台移出分组`)
      onClose()
      onSaved()
    } catch (e) {
      toast.error((e as Error).message)
    } finally {
      setSaving(false)
    }
  }

  return (
    <Dialog open onOpenChange={(open) => !open && onClose()}>
      <DialogContent onOpenAutoFocus={(e) => e.preventDefault()} className="sm:max-w-2xl">
        <DialogHeader>
          <DialogTitle>设置分组</DialogTitle>
          <DialogDescription className="leading-relaxed">
            勾选节点，设为同一个分组。改名或解散：先筛选出这个分组、全选，再填新名字或清空。
          </DialogDescription>
        </DialogHeader>
        <form noValidate className="contents" onSubmit={(e) => { e.preventDefault(); save() }}>
          <div className="space-y-4">
            <Field label="分组名" hint="公开页可见，最多 13 字；留空为移出分组">
              <GroupInput nodes={nodes} value={name} onChange={setName} />
            </Field>
            <NodePicker nodes={nodes} chosen={chosen} onPick={pick} />
          </div>
          <DialogFooter>
            <Button type="button" variant="ghost" onClick={onClose}>取消</Button>
            <Button type="submit" disabled={saving || !ids.length} className="max-w-full gap-0">
              <span className="truncate">{group ? `设为「${group}」` : "移出分组"}</span>
              {ids.length > 0 && <span className="tnum shrink-0">（{ids.length} 台）</span>}
            </Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  )
}


function CreateNode({ onClose, onSaved }: {
  onClose: () => void
  onSaved: (id: number) => void
}) {
  const [name, setName] = useState("")
  const [saving, setSaving] = useState(false)

  async function save(e: React.FormEvent) {
    e.preventDefault()
    if (!name.trim()) return toast.error("请填写节点名称")
    setSaving(true)
    try {
      const { id } = await api<{ id: number }>("/nodes", {
        method: "POST",
        body: JSON.stringify({ name: name.trim() }),
      })
      toast.success("节点已添加")
      onClose()
      onSaved(id)
    } catch (e) {
      toast.error((e as Error).message)
    } finally {
      setSaving(false)
    }
  }

  return (
    <Dialog open onOpenChange={(open) => !open && onClose()}>
      <DialogContent className="sm:max-w-md">
        <DialogHeader>
          <DialogTitle>添加节点</DialogTitle>
        </DialogHeader>
        <form className="space-y-4" onSubmit={save}>
          <Field label="名称">
            <Input autoFocus value={name} onChange={(e) => setName(e.target.value)} placeholder="香港 · 甲商家" />
          </Field>
          <DialogFooter className="border-t pt-4">
            <Button type="button" variant="ghost" onClick={onClose}>取消</Button>
            <Button type="submit" disabled={saving}>添加</Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  )
}


function NodeForm({ node, nodes, onClose, onSaved }: {
  node: Node
  nodes: Node[]
  onClose: () => void
  onSaved: () => void
}) {
  const [form, setForm] = useState(node)
  const [limitGib, setLimitGib] = useState(String(node.traffic_limit / GIB || ""))
  // Text, as the limit is: a number state turns an emptied box into 0.
  const [resetDay, setResetDay] = useState(String(node.traffic_reset_day))
  const [saving, setSaving] = useState(false)
  const gib = (bytes: number) => String(Number((bytes / GIB).toFixed(3)))
  const [traffic, setTraffic] = useState(() =>
    Object.fromEntries(TRAFFIC_FIELDS.map(([k]) => [k, gib(node[k])])) as Record<string, string>,
  )
  // Compared as entered rather than as bytes: rounding to GB would read as an
  // edit and zero a node that has transferred a few MB.
  const pristine = useRef(traffic)
  const set = <K extends keyof Node>(k: K, v: Node[K]) => setForm((f) => ({ ...f, [k]: v }))
  // What each address box falls back to when left empty.
  const automatic = (v6: boolean) => (v6 ? node.ipv6_auto : node.ipv4_auto) || "无"

  async function save() {
    if (!form.name.trim()) return toast.error("请填写节点名称")
    const resetOn = Number(resetDay)
    if (!Number.isInteger(resetOn) || resetOn < 1 || resetOn > 31) return toast.error("每月重置日要填 1–31 之间的整数")
    const patch = changes(node, {
      name: form.name.trim(),
      public: form.public,
      remark: form.remark,
      public_remark: (form.public_remark ?? "").trim(),
      group: (form.group ?? "").trim(),
      traffic_mode: form.traffic_mode,
      traffic_limit: Math.round(Number(limitGib) * GIB),
      traffic_reset_day: resetOn,
      notify: !!form.notify,
      ipv4_pin: (form.ipv4_pin ?? "").trim(),
      ipv6_pin: (form.ipv6_pin ?? "").trim(),
      country_pin: (form.country_pin ?? "").trim().toUpperCase(),
    })
    const correction = trafficCorrection(pristine.current, traffic)
    if ([patch.traffic_limit, ...Object.values(correction)].some((v) => v !== undefined && (!Number.isSafeInteger(v) || v < 0))) {
      return toast.error("流量必须是有效的非负数，且不能超出精确计数范围")
    }
    setSaving(true)
    try {
      // The correction belongs to the new reset period, so its day is saved
      // first.
      if (Object.keys(patch).length) {
        await api(`/nodes/${node.id}`, { method: "PUT", body: JSON.stringify(patch) })
      }
      if (Object.keys(correction).length) {
        await api(`/nodes/${node.id}/traffic`, {
          method: "PUT",
          body: JSON.stringify(correction),
        })
      }
      toast.success("节点设置已保存")
      onClose()
      onSaved()
    } catch (e) {
      toast.error((e as Error).message)
    } finally {
      setSaving(false)
    }
  }

  return (
    <Dialog open onOpenChange={(open) => !open && onClose()}>
      <DialogContent onOpenAutoFocus={(e) => e.preventDefault()} className="sm:max-w-2xl">
        <DialogHeader>
          <DialogTitle>{node.name}</DialogTitle>
        </DialogHeader>
        {/* noValidate here and in the other dialogs: save() checks every field.
            The browser's own check would refuse a fractional GB against the
            default step of 1, and cannot point at a field folded inside
            流量校正, so the save button would do nothing. */}
        <form noValidate className="contents" onSubmit={(e) => { e.preventDefault(); save() }}>
          <div className="space-y-6">
            <section className="space-y-4">
              <div className="grid gap-4 sm:grid-cols-2">
                <Field label="名称">
                  <Input value={form.name} onChange={(e) => set("name", e.target.value)} />
                </Field>
                <Field label="分组" hint="公开页可见，留空为未分组">
                  <GroupInput nodes={nodes} value={form.group ?? ""} onChange={(v) => set("group", v)} />
                </Field>
                <Field label="公开备注">
                  <Input
                    value={form.public_remark ?? ""}
                    onChange={(e) => set("public_remark", e.target.value)}
                    placeholder="公开页可见，最多 100 字"
                  />
                </Field>
                <Field label="私有备注">
                  <Input value={form.remark ?? ""} onChange={(e) => set("remark", e.target.value)} placeholder="仅管理员可见" />
                </Field>
              </div>
              <div className="grid gap-3 sm:grid-cols-2">
                <OptionRow title="公开显示" hint="关闭后只在管理后台可见" toggle>
                  <Switch checked={form.public} onCheckedChange={(v) => set("public", v)} />
                </OptionRow>
                <OptionRow title="离线通知" hint="掉线超过宽限期、恢复时各推一条" toggle>
                  <Switch checked={!!form.notify} onCheckedChange={(v) => set("notify", v)} />
                </OptionRow>
              </div>
            </section>
            <section className="space-y-3 border-t pt-5">
              <h3 className="text-sm font-medium">流量</h3>
              {/* On a phone the two short numbers share a row, the mode takes
                  the next; dense packing restores the order from sm up. */}
              <div className="grid grid-flow-row-dense grid-cols-2 gap-4 sm:grid-cols-3">
                <Field label="每月额度 (GB)" hint="留空或 0 不限">
                  <Input type="number" value={limitGib} onChange={(e) => setLimitGib(e.target.value)} placeholder="1024" />
                </Field>
                <Field label="计算方式" className="col-span-2 sm:col-span-1">
                  <Select value={form.traffic_mode} onValueChange={(v) => set("traffic_mode", v)}>
                    <SelectTrigger className="w-full"><SelectValue /></SelectTrigger>
                    <SelectContent position="popper">
                      {Object.entries(TRAFFIC_MODES).map(([k, v]) => (
                        <SelectItem key={k} value={k}>{v}</SelectItem>
                      ))}
                    </SelectContent>
                  </Select>
                </Field>
                <Field label="每月重置日" hint="1–31，改后本月重算，总量不变">
                  <Input type="number" min={1} max={31} value={resetDay} onChange={(e) => setResetDay(e.target.value)} />
                </Field>
              </div>
              <details className="rounded-lg border bg-muted/30 px-3 py-2.5">
                <summary className="cursor-pointer text-sm font-medium">流量校正</summary>
                <p className="mt-2 text-xs leading-relaxed text-muted-foreground">
                  按 GB 填入需要校正的值，未修改的计数器继续正常累计。
                </p>
                <div className="mt-3 grid grid-cols-2 gap-4">
                  {TRAFFIC_FIELDS.map(([key, label]) => (
                    <Field key={key} label={`${label} (GB)`}>
                      <Input
                        type="number"
                        step="0.001"
                        value={traffic[key]}
                        onChange={(e) => setTraffic((t) => ({ ...t, [key]: e.target.value }))}
                      />
                    </Field>
                  ))}
                </div>
              </details>
            </section>
            <section className="space-y-3 border-t pt-5">
              <h3 className="text-sm font-medium">地址与地区</h3>
              <div className="grid grid-flow-row-dense grid-cols-[1fr_5rem] gap-4 sm:grid-cols-[1fr_1.4fr_6rem]">
                <Field label="IPv4">
                  <Input value={form.ipv4_pin ?? ""} onChange={(e) => set("ipv4_pin", e.target.value)} placeholder={`自动：${automatic(false)}`} />
                </Field>
                <Field label="IPv6" className="col-span-full sm:col-span-1">
                  <Input value={form.ipv6_pin ?? ""} onChange={(e) => set("ipv6_pin", e.target.value)} placeholder={`自动：${automatic(true)}`} />
                </Field>
                <Field label="国家/地区">
                  <Input
                    value={form.country_pin ?? ""}
                    maxLength={2}
                    onChange={(e) => set("country_pin", e.target.value.toUpperCase())}
                    placeholder={`自动：${node.country_auto || "无"}`}
                  />
                </Field>
              </div>
              <p className="text-xs leading-relaxed text-muted-foreground">
                留空为自动。国家/地区填两位代码，如 CN；手填的值会一直显示，IP 变了要自己改。
              </p>
            </section>
          </div>
          <DialogFooter>
            <Button type="button" variant="ghost" onClick={onClose}>取消</Button>
            <Button type="submit" disabled={saving}>保存</Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  )
}


const CURRENCY_NAMES = new Intl.DisplayNames(["zh-CN"], { type: "currency" })


// The name confirms a code the hub can only check the shape of. DisplayNames
// echoes back a code outside ISO 4217 and throws on anything but three letters,
// which the hub refuses with its own message.
function currencyHint(code: string) {
  try {
    const name = CURRENCY_NAMES.of(code)
    return name === code ? "未知代码，照原样显示" : name
  } catch {
    return undefined
  }
}


function BillingForm({ node, onClose, onSaved }: {
  node: Node
  onClose: () => void
  onSaved: () => void
}) {
  const [form, setForm] = useState(node)
  // Text rather than a number: a numeric state cannot represent an empty field,
  // so clearing it would snap back to 0 mid-entry. Empty means free.
  const [price, setPrice] = useState(node.price > 0 ? String(node.price) : "")
  // Whole years are entered in years, the way a five-year plan is sold.
  const months = cycleMonths(node.billing_cycle)
  const [unit, setUnit] = useState(months === 0 ? "once" : months % 12 ? "months" : "years")
  const [count, setCount] = useState(String(months % 12 ? months : months / 12 || 1))
  const [saving, setSaving] = useState(false)
  const set = <K extends keyof Node>(k: K, v: Node[K]) => setForm((f) => ({ ...f, [k]: v }))

  async function save() {
    // The hub refuses a length out of range and stores a named one by name, so
    // an unchanged length is compared in months, not in spelling.
    const cycle = unit === "once" ? "once" : `${Number(count) * (unit === "years" ? 12 : 1)}m`
    setSaving(true)
    try {
      await api(`/nodes/${node.id}`, {
        method: "PUT",
        body: JSON.stringify(changes(node, {
          price: Math.max(0, Number(price) || 0),
          currency: form.currency,
          billing_cycle: cycleMonths(cycle) === months ? node.billing_cycle : cycle,
          expires_at: form.expires_at || null,
        })),
      })
      toast.success("续费设置已保存")
      onClose()
      onSaved()
    } catch (e) {
      toast.error((e as Error).message)
    } finally {
      setSaving(false)
    }
  }

  return (
    <Dialog open onOpenChange={(open) => !open && onClose()}>
      <DialogContent onOpenAutoFocus={(e) => e.preventDefault()} className="sm:max-w-md">
        <DialogHeader>
          <DialogTitle>{node.name}</DialogTitle>
        </DialogHeader>
        <form noValidate className="contents" onSubmit={(e) => { e.preventDefault(); save() }}>
          <div className="space-y-5">
            <div className="grid grid-cols-2 gap-4">
              <Field label="价格" hint="留空或 0 为免费">
                <Input
                  type="number"
                  min="0"
                  step="0.01"
                  value={price}
                  onChange={(e) => setPrice(e.target.value)}
                  placeholder="免费"
                />
              </Field>
              <Field
                label="货币"
                hint={currencyHint(form.currency.toUpperCase())}
                helpWidth="max-w-72"
                help={
                  <>
                    <p>填三个字母的货币代码，大小写都行。</p>
                    <p>
                      例如：
                      {["美元 USD", "人民币 CNY", "港币 HKD", "新台币 TWD", "欧元 EUR", "日元 JPY"].map((c, i) => (
                        <span key={c}>{i > 0 && "、"}<span className="whitespace-nowrap">{c}</span></span>
                      ))}
                    </p>
                  </>
                }
              >
                {/* Uppercased by CSS: rewriting the value mid-composition would
                    break an input method, and the hub stores it uppercased. */}
                <Input
                  maxLength={3}
                  autoCapitalize="characters"
                  spellCheck={false}
                  className="uppercase"
                  value={form.currency}
                  onChange={(e) => set("currency", e.target.value)}
                  placeholder="USD"
                />
              </Field>
            </div>
            <div className="grid grid-cols-2 gap-4">
              <Field label="付款周期">
                <div className="flex gap-2">
                  {unit !== "once" && (
                    <Input
                      type="number"
                      min="1"
                      step="1"
                      aria-label="周期长度"
                      className="w-16"
                      value={count}
                      onChange={(e) => setCount(e.target.value)}
                    />
                  )}
                  <Select value={unit} onValueChange={setUnit}>
                    <SelectTrigger className="min-w-0 flex-1"><SelectValue /></SelectTrigger>
                    <SelectContent position="popper">
                      <SelectItem value="months">月</SelectItem>
                      <SelectItem value="years">年</SelectItem>
                      <SelectItem value="once">一次性</SelectItem>
                    </SelectContent>
                  </Select>
                </div>
              </Field>
              <Field label="到期时间">
                <Input type="date" value={form.expires_at ?? ""} onChange={(e) => set("expires_at", e.target.value)} />
              </Field>
            </div>
          </div>
          <DialogFooter>
            <Button type="button" variant="ghost" onClick={onClose}>取消</Button>
            <Button type="submit" disabled={saving}>保存</Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  )
}


function scriptCommand(site: string, args: (site: string) => string[], acceptUnverified = false) {
  site = provisioningSite(site)
  return installScriptCommand(site, args(site), acceptUnverified)
}


// Built here rather than fetched: the node list already carries the token, so
// viewing an install command is a read rather than an action. Reissuing one to
// display it would take the running agent offline.
function installCommand(site: string, token: string, seconds: number | undefined, iface: string | undefined, acceptUnverified = false) {
  return scriptCommand(site, (s) => [`--server ${s}`, `--token ${token}`, ...intervalArg(seconds), ...ifaceArg(iface)], acceptUnverified)
}


// Left out untouched, as an untouched --iface is: a rerun then keeps what the
// machine already has.
function intervalArg(seconds: number | undefined) {
  return seconds === undefined ? [] : [`--interval ${seconds}`]
}


// '' is how install.sh is told to clear a value it would otherwise keep; a
// name needs no quoting, as ifaceSpec admits no shell metacharacter.
function ifaceArg(iface: string | undefined) {
  return iface === undefined ? [] : [`--iface ${iface || "''"}`]
}


// One command for a batch of machines. The key belongs to the hub, is valid only
// within the window it opened, and each machine exchanges it for a token of its
// own, so unlike an install command this text is no one's credential and can be
// sent to every machine as it is.
function registerCommand(site: string, key: string, seconds: number | undefined, iface: string | undefined, acceptUnverified = false) {
  return scriptCommand(site, (s) => [`--server ${s}`, `--register ${key}`, ...intervalArg(seconds), ...ifaceArg(iface)], acceptUnverified)
}


// Carries no token, so it is the same for every node and remains valid after the
// node is deleted.
function uninstallCommand(site: string, acceptUnverified = false) {
  return scriptCommand(site, () => ["--uninstall"], acceptUnverified)
}


// The window lives on the hub; this reads it back and counts down, which is also
// what makes an expired one disappear from the panel without interaction.
function useRegisterWindow() {
  const [key, setKey] = useState("")
  const [until, setUntil] = useState(0)
  const [now, setNow] = useState(() => Math.floor(Date.now() / 1000))

  useEffect(() => {
    api<Settings>("/settings")
      .then((s) => { setKey(String(s.register_key ?? "")); setUntil(Number(s.register_until ?? 0)) })
      .catch(() => {})
    const timer = setInterval(() => setNow(Math.floor(Date.now() / 1000)), 1000)
    return () => clearInterval(timer)
  }, [])

  return {
    key,
    left: key === "" ? 0 : Math.max(0, until - now),
    async open() {
      try {
        const w = await api<{ register_key: string; register_until: string }>("/register-window", { method: "POST" })
        setKey(w.register_key)
        setUntil(Number(w.register_until))
      } catch (e) {
        toast.error((e as Error).message)
      }
    },
    async close() {
      try {
        await api("/register-window", { method: "DELETE" })
        setKey("")
        setUntil(0)
        toast.success("注册窗口已关闭")
      } catch (e) {
        toast.error((e as Error).message)
      }
    },
  }
}


function RegisterDialog({ site, selfSigned, reg, onClose }: {
  site: string
  selfSigned: boolean
  reg: ReturnType<typeof useRegisterWindow>
  onClose: () => void
}) {
  const [acceptUnverified, setAcceptUnverified] = useState(selfSigned)
  const iface = useIfaceOption(undefined)
  const interval = useIntervalOption()
  const command = reg.left > 0 && iface.valid ? registerCommand(site, reg.key, interval.flag, iface.flag, acceptUnverified) : ""
  const clock = `${Math.floor(reg.left / 60)}:${String(reg.left % 60).padStart(2, "0")}`

  return (
    <Dialog open onOpenChange={(open) => !open && onClose()}>
      <DialogContent onOpenAutoFocus={(e) => e.preventDefault()} className="sm:max-w-xl">
        <DialogHeader>
          <DialogTitle>批量添加</DialogTitle>
        </DialogHeader>
        <div className="space-y-5">
          {/* One string: JSX turns a line break inside CJK text into a visible space. */}
          <p className="text-sm text-muted-foreground">
            {"开一个一小时的注册窗口。期间这条命令在任意机器上跑一次，那台机器就会自己出现在列表里，" +
              "名字默认取它的 hostname。命令里没有任何一台机器的凭证，可以同时发给多台机器。"}
          </p>
          <section className="space-y-3">
            <h3 className="text-sm font-medium">安装选项</h3>
            <CertificateOption site={site} enabled={acceptUnverified} onChange={setAcceptUnverified} />
            <IntervalOption option={interval} batch />
            <IfaceOption option={iface} batch />
          </section>
          {reg.left > 0 ? (
            <section className="space-y-2 border-t pt-5">
              <h3 className="text-sm font-medium">安装命令</h3>
              <Command className={`max-h-40 min-h-24 ${command ? "" : "text-muted-foreground"}`}>
                {command || "网卡名有误，改正后显示命令"}
              </Command>
              <PlaintextNote site={site} />
              {/* Per machine, so it cannot be part of the one command. */}
              <p className="text-xs leading-relaxed text-muted-foreground">
                要给某台单独起名，在它执行的命令末尾加 <code>--name 名字</code>，只对新建的节点生效。
                <a
                  className="ml-1 underline underline-offset-2 hover:text-foreground"
                  href="https://monitor-document.pages.dev/install/batch"
                  target="_blank"
                  rel="noreferrer"
                >
                  批量执行的做法
                </a>
              </p>
              <OptionRow title={`窗口 ${clock} 后自动关闭`} hint="到点自动失效，装完了也可以现在就关">
                <Button variant="outline" size="sm" onClick={reg.close}>立即关闭</Button>
              </OptionRow>
            </section>
          ) : (
            <Button onClick={reg.open}>开启一小时窗口</Button>
          )}
        </div>
        <DialogFooter>
          <Button variant="ghost" onClick={onClose}>关闭</Button>
          <Button onClick={() => copy(command)} disabled={!command}>
            <Copy className="size-4" /> 复制
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}


// The reporting interval both install dialogs offer, opening on the node's
// current one where the hub has read it from the reports. `flag` stays
// undefined until the field is changed, including back to what it opened on.
function useIntervalOption(current?: number | null) {
  const [typed, setTyped] = useState<string>()
  const text = typed ?? String(current ?? 1)
  const seconds = Math.min(3600, Math.max(1, Math.round(Number(text) || 1)))
  return { typed: text, setTyped, current, flag: typed === undefined ? undefined : seconds }
}


function IntervalOption({ option, batch = false }: { option: ReturnType<typeof useIntervalOption>; batch?: boolean }) {
  return (
    <OptionRow
      title="上报间隔"
      hint={batch ? "1–3600 秒，默认 1 秒。这一批机器都按这个间隔上报，机器多时可以调大" : (
        <>
          1–3600 秒，默认 1 秒。不改动时沿用机器上原有的间隔
          {option.current && <span className="mt-0.5 block">当前：{option.current} 秒</span>}
        </>
      )}
    >
      <span className="flex shrink-0 items-center gap-2 text-muted-foreground">
        {/* Text rather than number: no spinner arrows, and no wheel changing
            the value under a passing scroll. */}
        <Input
          inputMode="numeric"
          value={option.typed}
          onChange={(e) => option.setTyped(e.target.value.replace(/\D/g, ""))}
          aria-label="上报间隔（秒）"
          className="tnum h-8 w-20 bg-background text-right"
        />
        秒
      </span>
    </OptionRow>
  )
}


// The `--iface` part of an install command. Off leaves the flag out, and
// install.sh then keeps whatever the machine already has; on with both lists
// empty passes '' and restores the default rules. It opens on for a node whose
// agent reports a list, so reinstalling from here repeats that list rather than
// relying on the machine to remember it.
function useIfaceOption(current: string | undefined) {
  const [on, setOn] = useState(!!current)
  const [choice, setChoice] = useState<IfaceChoice>(() => ifaceChoice(current ?? ""))
  const bad = on ? badIfaceName(choice) : undefined
  const spec = ifaceSpec(choice)
  return { on, setOn, choice, setChoice, current, bad, valid: !bad, flag: on && spec !== null ? spec : undefined }
}


function describeIface(spec: string) {
  const { only, skip } = ifaceChoice(spec)
  const parts = [only && `只统计 ${only.replaceAll(",", "、")}`, skip && `不统计 ${skip.replaceAll(",", "、")}`]
  return parts.filter(Boolean).join("；") || "默认规则"
}


function IfaceOption({ option, batch = false }: { option: ReturnType<typeof useIfaceOption>; batch?: boolean }) {
  const { on, setOn, choice, setChoice, current, bad } = option
  const field = (list: keyof IfaceChoice, label: string, placeholder: string) => (
    <Field label={label}>
      <Input
        value={choice[list]}
        onChange={(e) => setChoice({ ...choice, [list]: e.target.value })}
        placeholder={placeholder}
        spellCheck={false}
        aria-invalid={bad?.list === list}
        className="bg-background font-mono text-xs"
      />
    </Field>
  )
  const hint = on
    ? batch ? "每台机器都按这里的设置统计" : "覆盖这台机器原有的设置"
    : batch ? "关闭时各台机器沿用原有设置，新机器按默认规则" : "关闭时沿用机器上原有的设置，转发流量的机器才需要指定"
  return (
    <OptionRow
      title="指定统计的网卡"
      hint={<>{hint}{current !== undefined && <span className="mt-0.5 block">当前：{describeIface(current)}</span>}</>}
      toggle
      below={on && (
        <div className="space-y-2.5">
          <div className="grid gap-3 sm:grid-cols-2">
            {field("only", "只统计", "如 WAN 口 eth1 或 pppoe-wan")}
            {field("skip", "不统计", "如 LAN 口 eth0")}
          </div>
          <p className={`text-xs leading-relaxed ${bad ? "text-destructive" : "text-muted-foreground"}`}>
            {bad
              ? `「${bad.name}」不是有效的网卡名：写完整的名字，多个用逗号分隔`
              : "写完整的网卡名，多个用逗号分隔。两项都留空即恢复默认规则。"}
          </p>
        </div>
      )}
    >
      <Switch checked={on} onCheckedChange={setOn} />
    </OptionRow>
  )
}


function InstallDialog({ node, site, selfSigned, onClose, onRotated }: {
  node: Node
  site: string
  selfSigned: boolean
  onClose: () => void
  onRotated: () => void
}) {
  const [token, setToken] = useState(node.token ?? "")
  const [rotating, setRotating] = useState(false)
  const [confirmRotate, setConfirmRotate] = useState(false)
  const iface = useIfaceOption(currentIface(node))
  const interval = useIntervalOption(node.interval)
  const [acceptUnverified, setAcceptUnverified] = useState(selfSigned)

  const command = iface.valid ? installCommand(site, token, interval.flag, iface.flag, acceptUnverified) : ""

  async function rotate() {
    setRotating(true)
    try {
      const fresh = await api<{ token: string }>(`/nodes/${node.id}/token`, { method: "POST" })
      setToken(fresh.token)
      setConfirmRotate(false)
      toast.success("凭证已换发，需用新命令重装")
      onRotated()
    } catch (e) {
      toast.error((e as Error).message)
    } finally {
      setRotating(false)
    }
  }

  return (
    <Dialog open onOpenChange={(open) => !open && onClose()}>
      <DialogContent onOpenAutoFocus={(e) => e.preventDefault()} className="sm:max-w-xl">
        <DialogHeader>
          <DialogTitle>{node.name}</DialogTitle>
          {/* The one place a single node's agent version is shown, and what an
              issue report asks for. Empty until the node has reported once. */}
          {node.agent_version && <DialogDescription>当前 agent v{node.agent_version}</DialogDescription>}
        </DialogHeader>
        <div className="space-y-5">
          <section className="space-y-3">
            <h3 className="text-sm font-medium">安装选项</h3>
            <CertificateOption site={site} enabled={acceptUnverified} onChange={setAcceptUnverified} />
            <IntervalOption option={interval} />
            <IfaceOption option={iface} />
          </section>
          <section className="space-y-2 border-t pt-5">
            <h3 className="text-sm font-medium">安装命令</h3>
            <Command className={`max-h-40 min-h-24 ${command ? "" : "text-muted-foreground"}`}>
              {command || "网卡名有误，改正后显示命令"}
            </Command>
            <PlaintextNote site={site} />
          </section>
          <OptionRow title="换发凭证" hint="旧凭证立即作废，agent 掉线，需用新命令重装">
            <Button variant="outline" size="sm" disabled={rotating} onClick={() => setConfirmRotate(true)}>
              换发
            </Button>
          </OptionRow>
        </div>
        <DialogFooter>
          <Button variant="ghost" onClick={onClose}>关闭</Button>
          <Button onClick={() => copy(command)} disabled={!command}>
            <Copy className="size-4" /> 复制
          </Button>
        </DialogFooter>
      </DialogContent>
      {confirmRotate && (
        <ConfirmDialog
          title={`给「${node.name}」换发凭证？`}
          description="旧凭证立即作废，agent 掉线，必须用新命令重装。仅在凭证可能泄露时使用。"
          confirmLabel="换发凭证"
          busy={rotating}
          onClose={() => setConfirmRotate(false)}
          onConfirm={rotate}
        />
      )}
    </Dialog>
  )
}


// Width in ems, near enough: a CJK character is one, anything else about half.
const ems = (word: string) => [...word].reduce((n, c) => n + (c > "\u2e7f" ? 1 : 0.55), 0)


// A node name, broken at its spaces and after the dots of a hostname --
// registered nodes are named after theirs. A word up to eight ems stays whole,
// a city, a label or a hyphenated one such as GIA-E, where the browser would
// leave its last letter to open the next line. A wider word, as a name typed
// without spaces usually is, breaks between its CJK characters, and a run of
// letters only where nothing else fits: kept whole, it would set the column's
// minimum width and push the table past the screen. A separator such as the ·
// in 香港 09 · DMIT, or a dash, is held to the word before it, so no line opens
// with one.
function nameText(name: string) {
  return name
    .replace(/ (?=[·|/｜—–-] )/g, "\u00a0")
    .split(/( )/)
    .map((word, i) => {
      const parts = word.split(".").flatMap((part, j) => (j ? [".", <wbr key={j} />, part] : [part]))
      if (ems(word) > 8) return <span key={i} className="wrap-anywhere [word-break:normal]">{parts}</span>
      return word.includes("-") ? <span key={i} className="whitespace-nowrap">{word}</span> : parts
    })
}


// Traffic turns a subdued orange at the alert threshold and a subdued red once
// the allowance is used up, so the table agrees with the alerts. With alerts
// off, the threshold's default of 80 % still marks a node running short.
function trafficTone(n: Node, warnAt: number) {
  if (n.traffic_limit <= 0) return ""
  if (n.month_used >= n.traffic_limit) return "text-over"
  return n.month_used * 100 >= n.traffic_limit * warnAt ? "text-near" : ""
}


export function Nodes({ nodes, refresh, site, selfSigned, refusal }: { nodes: Node[]; refresh: () => void; site: string; selfSigned: boolean; refusal: string }) {
  const warnAt = Number(useSettings().s?.notify_traffic) || 80
  // Preset from what the installer was told. A hub reached through a
  // self-signed certificate cannot be installed on a node without --insecure,
  // so leaving this off would hand out a command that fails -- and the operator,
  // who already answered this question when the hub was installed, is the one
  // who would have to notice and flip it.
  const [acceptUnverified, setAcceptUnverified] = useState(selfSigned)
  const [creating, setCreating] = useState(false)
  const [editing, setEditing] = useState<Node | null>(null)
  const [billing, setBilling] = useState<Node | null>(null)
  const [installing, setInstalling] = useState<Node | null>(null)
  const [registering, setRegistering] = useState(false)
  const reg = useRegisterWindow()
  const [deleting, setDeleting] = useState<Node | null>(null)
  const [removing, setRemoving] = useState(false)
  const [query, setQuery] = useState("")
  const [group, setGroup] = useGroupFilter(nodes)
  const [grouping, setGrouping] = useState(false)
  // A new node lands last, a hundred rows down on a large fleet, so it is
  // brought into view once the list carries it. A filter hiding it cancels the
  // scroll rather than leaving one to fire when the filter is cleared.
  const added = useRef<number | null>(null)
  const drag = useDragOrder(nodes, "nodes", refresh)
  const visible = inGroup(searchNodes(drag.order, query), group)
  useEffect(() => {
    if (added.current === null || !nodes.some((n) => n.id === added.current)) return
    document.querySelector(`tbody tr[data-id="${added.current}"]`)?.scrollIntoView({ block: "center", behavior: "smooth" })
    added.current = null
  })
  const searching = query.trim() !== "" || group !== "all"
  const uninstall = refusal ? "" : uninstallCommand(site, acceptUnverified)

  async function remove() {
    if (!deleting) return
    setRemoving(true)
    try {
      await api(`/nodes/${deleting.id}`, { method: "DELETE" })
      toast.success("已删除")
      setDeleting(null)
      refresh()
    } catch (e) {
      toast.error((e as Error).message)
    } finally {
      setRemoving(false)
    }
  }

  return (
    <div className="space-y-4">
      {refusal && <p className="text-sm text-muted-foreground">{refusal}</p>}
      <CertificateOption site={site} enabled={acceptUnverified} onChange={setAcceptUnverified} />
      <div className="flex flex-wrap items-center justify-end gap-2">
        <div className="mr-auto flex w-full gap-2 sm:w-auto">
          <NodeSearch className="min-w-0 flex-1 sm:w-64 sm:flex-none" value={query} onChange={setQuery} />
          <GroupFilter nodes={nodes} value={group} onChange={setGroup} className="w-32" />
        </div>
        <Button variant="outline" disabled={!nodes.length} onClick={() => setGrouping(true)}>
          <Layers /> 分组
        </Button>
        {/* An open window is visible from the list itself, so nobody has to
            remember they left one open. */}
        <Button variant="outline" disabled={!!refusal} onClick={() => setRegistering(true)}>
          <Server /> 批量添加{reg.left > 0 && ` · ${Math.ceil(reg.left / 60)} 分`}
        </Button>
        <Button disabled={!!refusal} onClick={() => setCreating(true)}>
          <Plus /> 添加节点
        </Button>
      </div>

      <Card className="overflow-x-auto p-0">
        <Table>
          <TableHeader>
            {/* Percentages, or the address column swallows every spare pixel
                and pushes status across the table. */}
            <TableRow>
              <TableHead className="w-[26%]">名称</TableHead>
              <TableHead className="w-[18%]">IP</TableHead>
              <TableHead className="w-[12%]">状态</TableHead>
              <TableHead className="w-[16%]">流量</TableHead>
              {/* Below xl the expiry date moves under the price: seven
                  columns leave a 1024px window no room for names. */}
              <TableHead className="w-[10%]">价格<span className="xl:hidden"> / 到期</span></TableHead>
              <TableHead className="hidden w-[12%] xl:table-cell">到期</TableHead>
              <TableHead className="text-right">操作</TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {visible.map((n) => (
              <TableRow key={n.id} {...drag.row(n.id)}>
                {/* Wraps: under the cell's default nowrap, one long name would
                    widen the table until the actions left the screen. */}
                <TableCell className="whitespace-normal">
                  <div className="flex items-center gap-2">
                    <DragHandle
                      {...drag.handle(n.id)}
                      name={n.name}
                      disabled={searching}
                      title={searching ? "清空搜索和分组筛选后可拖动排序" : undefined}
                    />
                    <div className="min-w-24">
                      {/* Lines are balanced, so none ends on a character or two. */}
                      <div className="font-medium text-balance break-keep">
                        {nameText(n.name)}
                        {/* In the name's flow, a fixed gap after its last word.
                            Beside the block it would sit at the cell's edge
                            whenever the name or group wraps, since a wrapped
                            block spans the whole width. The gap is a figure
                            space, which does not break: the badge moves down
                            with the last word rather than open a line alone. */}
                        {n.country && "\u2007"}
                        {n.country && (
                          <Badge
                            variant="outline"
                            title={n.country_pin ? "手动指定" : undefined}
                            className="align-middle font-normal text-muted-foreground"
                          >
                            {n.country}
                          </Badge>
                        )}
                      </div>
                      {n.group && <div className="text-xs text-balance text-muted-foreground">{n.group}</div>}
                    </div>
                  </div>
                </TableCell>
                {/* Addresses live only here, never on the public page. */}
                <TableCell>
                  <Addresses list={n.addresses ?? []} />
                </TableCell>
                <TableCell>
                  {/* Stacked and centred on one axis. The slot is as wide as
                      the three-character 不公开, so a lone pill sits where it
                      would above that one and every row lines up. */}
                  <div className="flex w-fit min-w-14 flex-col items-center gap-1">
                    <Badge variant={n.online ? "default" : "secondary"} className="font-normal">
                      {n.online ? "在线" : "离线"}
                    </Badge>
                    {!n.public && <Badge variant="outline" className="font-normal">不公开</Badge>}
                    {/* Under the badge, not inside it: the column is a tenth of
                        the table and the three do not share one line. A slot of
                        the pills' width that the text spills out of evenly, so a
                        long duration does not widen the slot and move the
                        pills off the axis the other rows share. */}
                    {!n.online && n.last_seen > 0 && Date.now() / 1000 - n.last_seen >= 60 && (
                      <div className="flex w-14 justify-center">
                        <span className="tnum text-xs whitespace-nowrap text-muted-foreground">
                          {uptime(Date.now() / 1000 - n.last_seen)}
                        </span>
                      </div>
                    )}
                  </div>
                </TableCell>
                {/* Counted by the node's own billing rule, as on the public
                    page. Two unbreakable halves, so a narrow table moves the
                    limit to a second line rather than splitting a figure. */}
                <TableCell className="tnum text-sm whitespace-normal">
                  <span className={`whitespace-nowrap ${trafficTone(n, warnAt)}`}>
                    {bytes(n.month_used)}
                  </span>{" "}
                  <span className="whitespace-nowrap text-muted-foreground">
                    / {n.traffic_limit > 0 ? bytes(n.traffic_limit) : FOREVER}
                  </span>
                </TableCell>
                <TableCell className="tnum text-sm">
                  {n.price > 0 ? money(n.price, n.currency) : "免费"}
                  <div className="text-xs text-muted-foreground xl:hidden">{n.expires_at || FOREVER}</div>
                </TableCell>
                <TableCell className="hidden text-sm xl:table-cell">{n.expires_at || FOREVER}</TableCell>
                <TableCell className="text-right whitespace-nowrap">
                  <Button variant="ghost" size="icon" disabled={!!refusal} onClick={() => setInstalling(n)} title="安装 Agent" aria-label="安装 Agent">
                    <Download />
                  </Button>
                  <Button variant="ghost" size="icon" onClick={() => setEditing(n)} title="编辑节点" aria-label="编辑节点">
                    <Pencil />
                  </Button>
                  <Button variant="ghost" size="icon" onClick={() => setBilling(n)} title="续费设置" aria-label="续费设置">
                    <CalendarClock />
                  </Button>
                  <Button variant="ghost" size="icon" onClick={() => setDeleting(n)} title="删除节点" aria-label="删除节点">
                    <Trash2 className="text-destructive" />
                  </Button>
                </TableCell>
              </TableRow>
            ))}
            {nodes.length === 0 && (
              <TableRow>
                <TableCell colSpan={7} className="py-10 text-center text-sm text-muted-foreground">
                  还没有节点，右上角添加
                </TableCell>
              </TableRow>
            )}
            {searching && nodes.length > 0 && !visible.length && (
              <TableRow>
                <TableCell colSpan={7} className="py-10 text-center text-sm text-muted-foreground">
                  没有匹配的节点
                </TableCell>
              </TableRow>
            )}
          </TableBody>
        </Table>
      </Card>

      {creating && (
        <CreateNode
          onClose={() => setCreating(false)}
          onSaved={(id) => { added.current = id; refresh() }}
        />
      )}
      {editing && (
        <NodeForm
          node={editing}
          nodes={nodes}
          onClose={() => setEditing(null)}
          onSaved={refresh}
        />
      )}
      {grouping && <GroupDialog nodes={drag.order} onClose={() => setGrouping(false)} onSaved={refresh} />}
      {billing && (
        <BillingForm node={billing} onClose={() => setBilling(null)} onSaved={refresh} />
      )}
      {registering && <RegisterDialog site={site} selfSigned={selfSigned} reg={reg} onClose={() => { setRegistering(false); refresh() }} />}

      {installing && (
        <InstallDialog
          node={installing}
          site={site}
          selfSigned={selfSigned}
          onClose={() => setInstalling(null)}
          onRotated={refresh}
        />
      )}
      {deleting && (
        <ConfirmDialog
          title={`删除节点「${deleting.name}」？`}
          description="历史指标、流量记录和凭证一并删除，不可恢复。"
          confirmLabel="删除节点"
          busy={removing}
          onClose={() => setDeleting(null)}
          onConfirm={remove}
        >
          {/* Deleting the node leaves the agent running on the machine, retrying
              with a token the hub no longer accepts. */}
          {uninstall && (
            <div className="space-y-2">
              <div className="flex items-center justify-between gap-2">
                <Label className="text-sm font-medium">卸载 agent</Label>
                <Button variant="ghost" size="sm" onClick={() => copy(uninstall)}>
                  <Copy className="size-4" /> 复制
                </Button>
              </div>
              <Command>{uninstall}</Command>
              <p className="text-xs text-muted-foreground">
                在这台机器上以 root 执行，停止 agent，删除二进制、env 文件和服务文件。
              </p>
            </div>
          )}
        </ConfirmDialog>
      )}
    </div>
  )
}
