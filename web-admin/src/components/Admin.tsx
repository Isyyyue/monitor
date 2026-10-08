import { lazy, Suspense } from "react"
import { Bell, Database, Globe, Palette, Radio, Rocket, Server, Shield } from "lucide-react"

import { type Node } from "@/lib/api"
import { Nodes } from "./admin/Nodes"

const Data = lazy(() => import("./admin/Data").then(m => ({ default: m.Data })))
const Deploy = lazy(() => import("./admin/Deploy").then(m => ({ default: m.Deploy })))
const Notify = lazy(() => import("./admin/Notify").then(m => ({ default: m.Notify })))
const Ping = lazy(() => import("./admin/Ping").then(m => ({ default: m.Ping })))
const Security = lazy(() => import("./admin/Security").then(m => ({ default: m.Security })))
const Themes = lazy(() => import("./admin/Themes").then(m => ({ default: m.Themes })))
const Website = lazy(() => import("./admin/Website").then(m => ({ default: m.Website })))


// Each area is its own route rather than a tab, so a page can be linked to and a
// reload returns to the same section.
const ADMIN_SECTIONS = [
  { path: "/admin/nodes", label: "节点", icon: Server },
  { path: "/admin/ping", label: "延迟", icon: Radio },
  { path: "/admin/notify", label: "通知", icon: Bell },
  { path: "/admin/data", label: "数据", icon: Database },
  { path: "/admin/themes", label: "主题", icon: Palette },
  { path: "/admin/security", label: "安全", icon: Shield },
  { path: "/admin/website", label: "网站", icon: Globe },
  { path: "/admin/deploy", label: "部署", icon: Rocket },
] as const


export function Admin({
  path,
  go,
  nodes,
  refresh,
  site,
  selfSigned,
  refusal,
}: {
  path: string
  go: (to: string) => void
  nodes: Node[]
  refresh: () => void
  site: string
  selfSigned: boolean
  refusal: string
  reloadMe: () => void
}) {
  return (
    <div className="flex flex-col gap-6 md:flex-row">
      <nav className="flex gap-1 overflow-x-auto md:w-44 md:shrink-0 md:flex-col md:overflow-visible">
        {ADMIN_SECTIONS.map(({ path: to, label, icon: Icon }) => {
          const active = path === to
          return (
            <button
              key={to}
              onClick={() => go(to)}
              aria-current={active ? "page" : undefined}
              className={`flex shrink-0 items-center gap-2 rounded-md px-3 py-2 text-sm transition-colors ${
                active ? "bg-secondary font-medium" : "text-muted-foreground hover:bg-muted"
              }`}
            >
              <Icon className="size-4" />
              {label}
            </button>
          )
        })}
      </nav>

      <div className="min-w-0 flex-1">
        <Suspense fallback={<p className="text-sm text-muted-foreground">加载中…</p>}>
        {path === "/admin/ping" ? (
          <Ping nodes={nodes} />
        ) : path === "/admin/notify" ? (
          <Notify nodes={nodes} refresh={refresh} />
        ) : path === "/admin/data" ? (
          <Data />
        ) : path === "/admin/themes" ? (
          <Themes />
        ) : path === "/admin/security" ? (
          <Security />
        ) : path === "/admin/website" ? (
          <Website />
        ) : path === "/admin/deploy" ? (
          <Deploy site={site} selfSigned={selfSigned} />
        ) : (
          <Nodes nodes={nodes} refresh={refresh} site={site} selfSigned={selfSigned} refusal={refusal} />
        )}
        </Suspense>
      </div>
    </div>
  )
}
