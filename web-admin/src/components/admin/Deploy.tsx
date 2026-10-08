import { useEffect, useState } from "react"
import { toast } from "sonner"

import { Button } from "@/components/ui/button"
import { Card } from "@/components/ui/card"
import { api } from "@/lib/api"
import { installScriptCommand } from "@/lib/install-command"
import { CertificateOption, Field } from "./shared"


export function Deploy({ site, selfSigned }: { site: string; selfSigned: boolean }) {
  const [acceptUnverified, setAcceptUnverified] = useState(selfSigned)
  const [nodes, setNodes] = useState<any[]>([])
  const [vpnInfo, setVpnInfo] = useState<Record<number, any>>({})
  // A set, not one id: the point of this page is comparing nodes, and a single
  // slot made opening the second close the first.
  const [open, setOpen] = useState<Set<number>>(new Set())

  const load = () => {
    api<{ nodes: any[] }>("/nodes").then((data) => {
      setNodes(data.nodes)
      // 加载每个节点的 VPN 信息
      data.nodes.forEach((n: any) => {
        api(`/nodes/${n.id}/vpn`).then(
          (vpn: any) => setVpnInfo((old) => ({ ...old, [n.id]: vpn })),
          () => setVpnInfo((old) => ({ ...old, [n.id]: null }))
        )
      })
    }).catch(() => setNodes([]))
  }
  useEffect(() => { load() }, [])

  const toggle = (id: number) => {
    setOpen((old) => {
      const next = new Set(old)
      if (next.has(id)) next.delete(id)
      else next.add(id)
      return next
    })
  }

  // sing-box and the subscription are written by `install.sh` on the node, as root,
  // once. The hub has no way to ask a node to do anything, so this is the command
  // that does it rather than a button that sends one.
  const command = (n: any) =>
    installScriptCommand(site, ["--upgrade", "--vpn", `--vpn-ip ${n.ip || "<节点公网IP>"}`], acceptUnverified)

  return (
    <div className="space-y-4">
      <Card className="gap-4 p-5">
        <div>
          <h3 className="text-sm font-medium">VPN 部署</h3>
          <CertificateOption site={site} enabled={acceptUnverified} onChange={setAcceptUnverified} />
          <p className="mt-1 text-xs text-muted-foreground">
            安装 Agent 默认只启用监控。复制下面的命令到节点上以 root 执行，才会部署 VPN 与订阅。
            已部署节点可使用同一命令重新部署，并复用已有凭据；面板不向节点下发安装指令。
          </p>
        </div>
        <div className="space-y-2">
          {nodes.map((n: any) => {
            const vpn = vpnInfo[n.id]
            const hasVpn = vpn && vpn.vless_link
            const expanded = open.has(n.id)
            return (
              <div key={n.id} className="rounded-lg border p-3">
                <div className="flex items-center justify-between">
                  <div>
                    <div className="font-medium">{n.name || `节点 ${n.id}`}</div>
                    <div className="text-xs text-muted-foreground">
                      {n.online ? "在线" : "离线"} · {hasVpn ? "已部署 VPN" : "未部署 VPN"}
                    </div>
                  </div>
                  <Button size="sm" variant="outline" onClick={() => toggle(n.id)}>
                    {expanded ? "关闭" : hasVpn ? "查看链接" : "部署命令"}
                  </Button>
                </div>
                {expanded && (
                  <div className="mt-3 space-y-3 border-t pt-3">
                    {hasVpn ? (
                      <>
                        {vpn.clash_sub_url && (
                          <Field label="Clash 订阅">
                            <div className="flex gap-2">
                              <div className="flex-1 rounded-md border bg-muted/50 p-2 font-mono text-xs break-all">
                                {vpn.clash_sub_url}
                              </div>
                              <Button size="sm" onClick={() => { navigator.clipboard.writeText(vpn.clash_sub_url); toast.success("已复制") }}>复制</Button>
                            </div>
                          </Field>
                        )}
                        {vpn.v2ray_sub_url && (
                          <Field label="v2rayN 订阅">
                            <div className="flex gap-2">
                              <div className="flex-1 rounded-md border bg-muted/50 p-2 font-mono text-xs break-all">
                                {vpn.v2ray_sub_url}
                              </div>
                              <Button size="sm" onClick={() => { navigator.clipboard.writeText(vpn.v2ray_sub_url); toast.success("已复制") }}>复制</Button>
                            </div>
                          </Field>
                        )}
                      </>
                    ) : (
                      <p className="text-xs text-muted-foreground">
                        该节点尚未部署 VPN。在节点上执行下面的命令即可。
                      </p>
                    )}
                    <Field label="部署命令">
                      <div className="flex gap-2">
                        <div className="flex-1 rounded-md border bg-muted/50 p-2 font-mono text-xs break-all">
                          {command(n)}
                        </div>
                        <Button size="sm" onClick={() => { navigator.clipboard.writeText(command(n)); toast.success("已复制") }}>复制</Button>
                      </div>
                    </Field>
                    <p className="text-xs text-muted-foreground">
                      重新执行会复用节点上已有的凭据，已发出的链接不受影响。
                    </p>
                  </div>
                )}
              </div>
            )
          })}
          {nodes.length === 0 && (
            <p className="text-sm text-muted-foreground">暂无节点</p>
          )}
        </div>
      </Card>
    </div>
  )
}
