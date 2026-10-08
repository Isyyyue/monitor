import { CircleQuestionMark, GripVertical, Search } from "lucide-react"
import { useEffect, useRef, useState } from "react"
import { flushSync } from "react-dom"
import { toast } from "sonner"

import { Button } from "@/components/ui/button"
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from "@/components/ui/dialog"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select"
import { Switch } from "@/components/ui/switch"
import { Tooltip, TooltipContent, TooltipTrigger } from "@/components/ui/tooltip"
import { api, groupsOf, inGroup, type Node } from "@/lib/api"


// Displaced rows slide from where they were drawn to their new place: each is
// offset back by the distance it moved, then released. Transforms leave layout
// and stacking alone, so hit-testing mid-slide reads layout positions and the
// sticky header stays on top. A slide cut short restarts from where it was drawn.
export function slide(rows: HTMLTableSectionElement | null, update: () => void) {
  const before = new Map([...(rows?.rows ?? [])].map((row) => [row, row.getBoundingClientRect().top]))
  for (const row of before.keys()) row.getAnimations().forEach((a) => a.id === "slide" && a.cancel())
  flushSync(update)
  if (matchMedia("(prefers-reduced-motion: reduce)").matches) return
  for (const [row, top] of before) {
    const dy = top - row.getBoundingClientRect().top
    if (dy) row.animate({ transform: [`translateY(${dy}px)`, "none"] }, { id: "slide", duration: 150, easing: "ease-out" })
  }
}


// Drag-to-reorder for a table whose order the hub stores at `/${path}/order`.
// Rows are displaced while the pointer is down and the whole order is saved on
// release, so a filtered table must disable its handles: the rows on screen are
// then not `order`.
export function useDragOrder<T extends { id: number }>(items: T[], path: string, reload: () => void) {
  const [manualOrder, setManualOrder] = useState<number[]>([])
  const [dragging, setDragging] = useState<number | null>(null)
  const orderBeforeDrag = useRef<number[]>([])
  const body = useRef<HTMLTableSectionElement | null>(null)
  // One save in flight at a time, so two quick reorders reach the hub in order.
  const saving = useRef<Promise<unknown>>(Promise.resolve())
  const byId = new Map(items.map((item) => [item.id, item]))
  const orderedIds = new Set(manualOrder)
  const order = [
    ...manualOrder.map((id) => byId.get(id)).filter((item): item is T => Boolean(item)),
    ...items.filter((item) => !orderedIds.has(item.id)),
  ]
  const ids = () => order.map((item) => item.id)

  // Once the hub lists this order, its list is followed again, so a reorder made
  // in another tab appears here instead of being overwritten by the next drag.
  if (dragging === null && manualOrder.length && manualOrder.join() === items.map((item) => item.id).join()) {
    setManualOrder([])
  }

  // Handled on the document by layout position, not by the row under the
  // pointer: a sliding row is drawn away from its place, and the one under the
  // pointer mid-slide is not the one it would displace. Re-attached on every
  // render, since `order` changes as rows are displaced.
  //
  // Dragenter is accepted as well as dragover: over a new element the browser
  // fires only dragenter until its next update, and a release in between -- as
  // when a reorder brings another row under a still pointer -- would otherwise
  // count as a drop outside and restore the order.
  useEffect(() => {
    const rows = body.current
    if (dragging === null || !rows) return
    const over = (e: DragEvent) => {
      // The header row counts as inside: a drag to the top readily overshoots
      // onto it, and a release there would otherwise discard the drag.
      const table = rows.parentElement!.getBoundingClientRect()
      if (e.clientX < table.left || e.clientX > table.right || e.clientY < table.top || e.clientY > table.bottom) return
      e.preventDefault()
      if (e.type === "drop") return
      if (e.dataTransfer) e.dataTransfer.dropEffect = "move"
      const list = [...rows.rows]
      // Offsets count from the rows' container, which does not slide.
      const y = e.clientY - list[0].offsetParent!.getBoundingClientRect().top
      const from = list.findIndex((row) => row.dataset.id === String(dragging))
      const to = list.findIndex((row) => y >= row.offsetTop && y < row.offsetTop + row.offsetHeight)
      if (from < 0 || to < 0 || from === to) return
      // Moved only where the pointer would then rest on the dragged row. Rows
      // differ in height: a short row moved past a tall one would leave the
      // tall one under the pointer, and the two would swap back and forth.
      const target = list[to]
      const height = list[from].offsetHeight
      if (to > from ? y < target.offsetTop + target.offsetHeight - height : y >= target.offsetTop + height) return
      move(dragging, to)
    }
    const types = ["dragenter", "dragover", "drop"] as const
    for (const type of types) document.addEventListener(type, over)
    return () => {
      for (const type of types) document.removeEventListener(type, over)
    }
  })

  function move(id: number, to: number) {
    const next = [...ids()]
    const from = next.indexOf(id)
    if (from < 0 || to < 0 || to >= next.length || from === to) return
    next.splice(to, 0, ...next.splice(from, 1))
    slide(body.current, () => setManualOrder(next))
    return next
  }

  // Dropped outside the table or cancelled with Escape: the order is restored.
  function cancel() {
    setDragging(null)
    const before = orderBeforeDrag.current
    if (before.length) slide(body.current, () => setManualOrder(before))
  }

  function save(next: number[]) {
    setDragging(null)
    const before = orderBeforeDrag.current
    if (!before.length || next.join() === before.join()) return
    orderBeforeDrag.current = next
    const put = () => api(`/${path}/order`, { method: "PUT", body: JSON.stringify({ ids: next }) })
    // A refusal falls back to whatever the hub holds, which a save queued
    // behind it may still change.
    saving.current = saving.current.then(put).then(reload, (e: Error) => {
      setManualOrder([])
      reload()
      toast.error(e.message)
    })
  }

  return {
    order,
    row: (id: number) => ({
      "data-id": id,
      "data-dragging": dragging === id || undefined,
      // Opaque, with the dragged row beneath the rest: two rows crossing mid-slide
      // would otherwise draw their text over each other. No hover tint during a
      // drag, since the browser keeps it on whichever row reaches the start point.
      className: `relative z-1 bg-card transition-opacity data-[dragging]:z-0 data-[dragging]:opacity-40 ${dragging === null ? "" : "hover:bg-card"}`,
    }),
    handle: (id: number) => ({
      onDragStart: (e: React.DragEvent<HTMLElement>) => {
        orderBeforeDrag.current = ids()
        body.current = e.currentTarget.closest("tbody")
        setDragging(id)
        e.dataTransfer.effectAllowed = "move"
        // Firefox refuses to start a drag without a payload.
        e.dataTransfer.setData("text/plain", String(id))
      },
      onDragEnd: (e: React.DragEvent) => (e.dataTransfer.dropEffect === "none" ? cancel() : save(ids())),
      onKeyDown: (e: React.KeyboardEvent) => {
        const delta = e.key === "ArrowUp" ? -1 : e.key === "ArrowDown" ? 1 : 0
        if (!delta) return
        e.preventDefault()
        orderBeforeDrag.current = ids()
        body.current = e.currentTarget.closest("tbody")
        const next = move(id, ids().indexOf(id) + delta)
        if (next) save(next)
      },
    }),
  }
}


export function DragHandle({ name, disabled, title = "拖动排序", ...events }: React.ComponentProps<"button"> & { name: string }) {
  return (
    <button
      type="button"
      draggable={!disabled}
      disabled={disabled}
      className="cursor-grab touch-none rounded p-1 text-muted-foreground hover:bg-muted hover:text-foreground active:cursor-grabbing disabled:cursor-default disabled:opacity-40 disabled:hover:bg-transparent"
      title={title}
      aria-label={`拖动 ${name} 排序`}
      {...events}
    >
      <GripVertical className="size-4" />
    </button>
  )
}


export function copy(text: string, done = "已复制") {
  // navigator.clipboard exists only in a secure context. Over plain http the
  // copy command still works from a click, the clipboard filled from its event.
  if (!navigator.clipboard) {
    const put = (e: ClipboardEvent) => { e.clipboardData?.setData("text/plain", text); e.preventDefault() }
    document.addEventListener("copy", put)
    const ok = document.execCommand("copy")
    document.removeEventListener("copy", put)
    return ok ? toast.success(done) : toast.error("复制失败")
  }
  navigator.clipboard.writeText(text).then(
    () => toast.success(done),
    () => toast.error("复制失败"),
  )
}


// Name, address, country and group: what a node is looked up by, in every node list.
export function searchNodes(nodes: Node[], query: string) {
  const needle = query.trim().toLowerCase()
  if (!needle) return nodes
  return nodes.filter((n) =>
    [n.name, n.ip, n.ipv4, n.ipv6, n.ipv4_pin, n.ipv6_pin, n.country, n.group].some((v) => v?.toLowerCase().includes(needle)))
}


// A filter naming a group no node carries any more -- renamed, or its last node
// deleted -- falls back to all rather than showing an empty list; so does 未分组
// once no group is left, since the dropdown that would clear it is hidden then.
// Reset rather than masked, so the old filter does not return with a later group
// of the same name.
export function useGroupFilter(nodes: Node[]) {
  const [filter, setFilter] = useState("all")
  const valid = filter === "all"
    || (filter === "none" ? nodes.some((n) => n.group) : nodes.some((n) => n.group === filter.slice(1)))
  if (!valid) setFilter("all")
  return [valid ? filter : "all", setFilter] as const
}


// Offered once some node has a group. 未分组 is where a batch of freshly
// registered machines waits to be assigned one.
export function GroupFilter({ nodes, value, onChange, className = "" }: {
  nodes: Node[]
  value: string
  onChange: (value: string) => void
  className?: string
}) {
  const groups = groupsOf(nodes)
  if (!groups.length) return null
  return (
    <Select value={value} onValueChange={onChange}>
      <SelectTrigger className={className} aria-label="按分组筛选"><SelectValue /></SelectTrigger>
      <SelectContent position="popper">
        <SelectItem value="all">全部分组</SelectItem>
        {groups.map((g) => <SelectItem key={g} value={`=${g}`}>{g}</SelectItem>)}
        <SelectItem value="none">未分组</SelectItem>
      </SelectContent>
    </Select>
  )
}


export function NodeSearch({ value, onChange, className = "" }: { value: string; onChange: (value: string) => void; className?: string }) {
  return (
    <div className={`relative ${className}`}>
      <Search className="pointer-events-none absolute top-1/2 left-2.5 size-4 -translate-y-1/2 text-muted-foreground" />
      <Input
        className="pl-8"
        placeholder="名称/地址/地区/分组"
        aria-label="搜索节点"
        value={value}
        onChange={(e) => onChange(e.target.value)}
        // Inside a dialog's form, Enter would otherwise save the dialog.
        onKeyDown={(e) => e.key === "Enter" && e.preventDefault()}
      />
    </div>
  )
}


// Ticks nodes in a searchable grid. 全选 and 全不选 act on the rows in view, so a
// search or a group narrows what they touch: pick a group, then 全选. Offline
// nodes are dimmed but remain selectable.
export function NodePicker({ nodes, chosen, onPick, disabled = false }: {
  nodes: Node[]
  chosen: Set<number>
  onPick: (list: Node[], on: boolean) => void
  disabled?: boolean
}) {
  const [query, setQuery] = useState("")
  const [group, setGroup] = useGroupFilter(nodes)
  // The unfiltered list's height, held as its floor: in a centred dialog a
  // shrinking list would move the search box out from under the cursor.
  const [listHeight, setListHeight] = useState(0)
  const visible = inGroup(searchNodes(nodes, query), group)
  const visibleChosen = visible.filter((n) => chosen.has(n.id)).length
  return (
    <div className="rounded-lg border">
      <div className="flex flex-wrap items-center gap-1 border-b p-2">
        <NodeSearch className="min-w-0 flex-1 basis-40" value={query} onChange={setQuery} />
        <GroupFilter nodes={nodes} value={group} onChange={setGroup} className="w-32" />
        <Button type="button" size="sm" variant="ghost" className="px-2.5" disabled={disabled || visibleChosen === visible.length} onClick={() => onPick(visible, true)}>全选</Button>
        <Button type="button" size="sm" variant="ghost" className="px-2.5" disabled={disabled || visibleChosen === 0} onClick={() => onPick(visible, false)}>全不选</Button>
      </div>
      {/* Three columns keep a few dozen nodes within one scroll. A phone gets
          one: two cut a name to a few characters, and a tap shows no title. */}
      <div
        ref={(el) => { if (el && !listHeight) setListHeight(el.offsetHeight) }}
        // Capped like the height itself, which a min-height would otherwise
        // override once the viewport shrinks.
        style={{ minHeight: listHeight ? `min(${listHeight}px, 16rem, 40dvh)` : undefined }}
        className="grid max-h-[min(16rem,40dvh)] grid-cols-1 content-start gap-0.5 overflow-y-auto p-1.5 min-[480px]:grid-cols-2 sm:grid-cols-3"
      >
        {visible.map((n) => (
          <label key={n.id} title={n.group ? `${n.name} · ${n.group}` : n.name} className="flex min-w-0 cursor-pointer items-center gap-2 rounded-md px-2 py-1.5 text-sm hover:bg-muted">
            <input type="checkbox" checked={chosen.has(n.id)} disabled={disabled} onChange={(e) => onPick([n], e.target.checked)} className="shrink-0 accent-primary" />
            <span className={`truncate ${n.online ? "" : "text-muted-foreground"}`}>{n.name}</span>
            {n.country && <span className="ml-auto shrink-0 text-xs text-muted-foreground">{n.country}</span>}
          </label>
        ))}
        {!visible.length && (
          <p className="col-span-full p-2 text-xs text-muted-foreground">{nodes.length ? "没有匹配的节点" : "先添加节点"}</p>
        )}
      </div>
    </div>
  )
}


export function Field({ label, hint, help, helpWidth, className = "", children }: {
  label: string
  hint?: string
  help?: React.ReactNode
  helpWidth?: string
  className?: string
  children: React.ReactNode
}) {
  const title = <Label className="text-sm font-medium">{label}</Label>
  return (
    <div className={`space-y-2 ${className}`}>
      {help ? <div className="flex items-center gap-1.5">{title}<Help width={helpWidth}>{help}</Help></div> : title}
      {children}
      {hint && <p className="text-xs leading-relaxed text-muted-foreground">{hint}</p>}
    </div>
  )
}


// A tap shows no tooltip on its own, so a click opens it as well. The trigger's
// own handlers would close it on press and on click; both are prevented.
//
// `width` is fitted to each text: the narrowest at which its paragraphs take the
// fewest lines, plus some room for a wider font. A screen too narrow for that
// gets the narrowest width holding the lines it can fit; capping the wide box
// at the screen instead would leave its lines well short of the right edge.
export function Help({ children, width = "max-w-64" }: { children: React.ReactNode; width?: string }) {
  const [open, setOpen] = useState(false)
  return (
    <Tooltip open={open} onOpenChange={setOpen}>
      <TooltipTrigger asChild>
        <button
          type="button"
          aria-label="说明"
          className="text-muted-foreground hover:text-foreground"
          onPointerDown={(e) => e.preventDefault()}
          onClick={(e) => {
            e.preventDefault()
            setOpen(true)
          }}
        >
          <CircleQuestionMark className="size-3.5" />
        </button>
      </TooltipTrigger>
      {/* text-wrap over the component's text-balance, which breaks multi-line
          Chinese halfway across the box. Chinese may also break between any
          two characters, which splits words such as 季付 across lines; kept
          whole, a line breaks at punctuation and spaces, and mid-run only when
          a run cannot fit at all. */}
      <TooltipContent
        collisionPadding={16}
        className={`${width} space-y-1 text-left text-wrap break-keep wrap-anywhere`}
      >
        {children}
      </TooltipContent>
    </Tooltip>
  )
}


// A titled option with its control at the right. `toggle` makes the whole row a
// label, so a click anywhere flips the Switch it holds; `below` opens beneath it
// in the same card.
export function OptionRow({ title, hint, toggle = false, below, children }: {
  title: React.ReactNode
  hint?: React.ReactNode
  toggle?: boolean
  below?: React.ReactNode
  children: React.ReactNode
}) {
  const Row = toggle ? "label" : "div"
  return (
    <div className="flex flex-col rounded-lg border bg-muted/30 text-sm">
      {/* flex-1: stretched by a grid, the row fills the card and stays clickable. */}
      <Row className={`flex flex-1 items-center justify-between gap-4 px-3 py-2.5 ${toggle ? "cursor-pointer" : ""}`}>
        <span>
          <span className="block font-medium">{title}</span>
          {hint && <span className="mt-0.5 block text-xs text-muted-foreground">{hint}</span>}
        </span>
        {children}
      </Row>
      {below && <div className="border-t px-3 pt-3 pb-3.5">{below}</div>}
    </div>
  )
}


export function ConfirmDialog({ title, description, confirmLabel, busy = false, onClose, onConfirm, children }: {
  title: string
  description: string
  confirmLabel: string
  busy?: boolean
  onClose: () => void
  onConfirm: () => void
  children?: React.ReactNode
}) {
  return (
    <Dialog open onOpenChange={(open) => !open && onClose()}>
      <DialogContent className="sm:max-w-md">
        <DialogHeader>
          <DialogTitle>{title}</DialogTitle>
          <DialogDescription className="leading-relaxed">{description}</DialogDescription>
        </DialogHeader>
        {children}
        <DialogFooter className="border-t pt-4">
          <Button variant="ghost" onClick={onClose}>取消</Button>
          <Button variant="destructive" onClick={onConfirm} disabled={busy}>{confirmLabel}</Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}


// Each command runs the hub's own install.sh and is offered on the entry --site
// names: an https domain, or a plaintext address for a hub that has none. `args`
// receives that entry, which the agent is also given as --server.
export function CertificateOption({ site, enabled, onChange }: { site: string; enabled: boolean; onChange: (value: boolean) => void }) {
  if (!site.startsWith("https:")) return null
  return <OptionRow title="接受未验证的 HTTPS 证书" hint="仅在确认使用自签证书时开启。下载与连接会跳过服务器身份验证。">
    <Switch checked={enabled} onCheckedChange={onChange} aria-label="接受未验证的 HTTPS 证书" />
  </OptionRow>
}


export type Settings = Record<string, string | boolean>


// Two pages write settings, and each loads only what it displays.
export function useSettings() {
  const [s, setS] = useState<Settings | null>(null)
  useEffect(() => { api<Settings>("/settings").then(setS).catch(() => {}) }, [])
  return {
    s,
    set: (k: string, v: string) => setS((old) => ({ ...(old ?? {}), [k]: v })),
    // Resolves to whether the hub took the patch; a failure is already toasted.
    save: async (patch: Record<string, string>, done = "已保存") => {
      try {
        await api("/settings", { method: "PUT", body: JSON.stringify(patch) })
      } catch (e) {
        toast.error((e as Error).message)
        return false
      }
      toast.success(done)
      // Only the saved keys and the `*_set` flags are taken from the hub: a
      // credential comes back as a flag, so the typed value must not linger,
      // while another card's unsaved edits on the same page must survive. A
      // failed read leaves the form as typed; the save itself stands.
      try {
        const fresh = await api<Settings>("/settings")
        setS((old) => {
          const next = { ...old }
          for (const key of Object.keys(patch)) next[key] = fresh[key]
          for (const [key, value] of Object.entries(fresh)) if (key.endsWith("_set")) next[key] = value
          return next
        })
      } catch (e) {
        toast.error((e as Error).message)
      }
      return true
    },
  }
}


// `onSaved` refreshes what the header shows, the site name among it.
export const TEXT_BOX =
  "w-full min-w-0 rounded-md border border-input bg-transparent px-3 py-2 shadow-xs outline-none placeholder:text-muted-foreground focus-visible:border-ring focus-visible:ring-[3px] focus-visible:ring-ring/50 dark:bg-input/30"
