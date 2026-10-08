import { Trash2 } from "lucide-react"
import { useCallback, useEffect, useState } from "react"
import { toast } from "sonner"

import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import { Card } from "@/components/ui/card"
import { Input } from "@/components/ui/input"
import { api } from "@/lib/api"
import { Field, useSettings } from "./shared"


type Session = { id: string; current: boolean; created_at: number }


function useSessions() {
  const [rows, setRows] = useState<Session[] | null>(null)
  // A failed load leaves the list empty rather than absent: the security page
  // waits for it, and the password card must stay reachable.
  const load = useCallback(
    () =>
      api<Session[]>("/sessions")
        .then(setRows)
        .catch((e: Error) => {
          toast.error(e.message)
          setRows((rows) => rows ?? [])
        }),
    [],
  )
  useEffect(() => { load() }, [load])
  return { rows, load }
}


function Sessions({ rows, reload }: { rows: Session[]; reload: () => void }) {
  const [busy, setBusy] = useState("")

  async function remove(id: string) {
    setBusy(id)
    try {
      await api(`/sessions/${id}`, { method: "DELETE" })
      toast.success("已删除会话")
      reload()
    } catch (e) {
      toast.error((e as Error).message)
    } finally {
      setBusy("")
    }
  }

  return (
    <Card className="gap-4 p-5">
      <div>
        <h3 className="text-sm font-medium">登录会话</h3>
        <p className="mt-1 text-xs text-muted-foreground">
          每次登录一条，14 天后过期。删除后该设备下一次请求就被登出。
        </p>
      </div>
      <div className="divide-y">
        {rows.map((s) => (
          <div key={s.id} className="flex items-center justify-between gap-3 py-2.5 first:pt-0 last:pb-0">
            <div className="flex min-w-0 items-center gap-2 text-sm">
              <span className="tnum">{new Date(s.created_at * 1000).toLocaleString("zh-CN")}</span>
              {s.current && <Badge variant="secondary">当前设备</Badge>}
            </div>
            {/* 当前会话没有删除按钮：右上角的退出登录做的就是这件事，而在这里删
                只会让已经渲染好的面板以为自己还登着。 */}
            {!s.current && (
              <Button size="icon" variant="ghost" title="删除会话" aria-label="删除会话" disabled={!!busy} onClick={() => remove(s.id)}>
                <Trash2 />
              </Button>
            )}
          </div>
        ))}
      </div>
    </Card>
  )
}


export function Security() {
  const { s } = useSettings()
  const sessions = useSessions()
  const [oldPassword, setOldPassword] = useState("")
  const [password, setPassword] = useState("")
  // Drawn once both have arrived, so the list does not land late above the
  // cards and push them down.
  if (!s || !sessions.rows) return null

  return (
    <div className="space-y-4">
      <Sessions rows={sessions.rows} reload={sessions.load} />

      <Card className="gap-4 p-5">
        <div>
          <h3 className="text-sm font-medium">修改密码</h3>
          <p className="mt-1 text-xs text-muted-foreground">
            修改后其它设备登录立即失效，当前设备不受影响。
          </p>
        </div>
        <Field label="旧密码">
          <Input type="password" value={oldPassword} onChange={(e) => setOldPassword(e.target.value)} autoComplete="current-password" />
        </Field>
        <Field label="新密码" hint="至少 12 位">
          <Input type="password" value={password} onChange={(e) => setPassword(e.target.value)} autoComplete="new-password" />
        </Field>
        <div>
          <Button
            size="sm"
            disabled={!oldPassword || password.length < 12}
            // Every other session ends with the change, so the list is read again.
            onClick={async () => {
              try {
                await api("/change-password", { method: "POST", body: JSON.stringify({ old_password: oldPassword, new_password: password }) })
                toast.success("密码已修改")
                setOldPassword("")
                setPassword("")
                sessions.load()
              } catch (e) {
                toast.error((e as Error).message)
              }
            }}
          >
            修改密码
          </Button>
        </div>
      </Card>
    </div>
  )
}
