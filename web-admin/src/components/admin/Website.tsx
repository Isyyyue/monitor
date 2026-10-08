import { Copy } from "lucide-react"
import { useState } from "react"

import { Button } from "@/components/ui/button"
import { Card } from "@/components/ui/card"
import { Input } from "@/components/ui/input"
import { copy, Field } from "./shared"


// The ways into this panel, on their own page: the sessions signed in, the
// GitHub identity it trusts and the password that works when GitHub does not.
export function Website() {
  const [domain, setDomain] = useState(() => {
    const h = window.location.hostname
    // 如果当前就是通过域名访问的，直接填入
    return h && !/^[\d.]+$/.test(h) && h !== "localhost" ? h : ""
  })
  const currentHost = window.location.hostname
  const alreadyBound = currentHost && !/^[\d.]+$/.test(currentHost) && currentHost !== "localhost"

  // The upgrade map and the two headers below are what keep the panel's live
  // view working: it is one long-lived WebSocket, and a proxy that passes it
  // through as an ordinary request leaves the page connected until it silently
  // stops updating. `install-hub.sh --https` writes the same three lines; a
  // configuration copied from here has to be no worse, or following the panel's
  // own instructions would break the panel.
  const nginxConf = domain.trim()
    ? `map $http_upgrade $connection_upgrade {
    default upgrade;
    ""      close;
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name ${domain.trim()};

    ssl_certificate /etc/letsencrypt/live/${domain.trim()}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${domain.trim()}/privkey.pem;

    location / {
        proxy_pass http://127.0.0.1:28080;
        proxy_http_version 1.1;
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header Upgrade           $http_upgrade;
        proxy_set_header Connection        $connection_upgrade;
        proxy_read_timeout 3600s;
    }
}`
    : ""

  const commands = domain.trim()
    ? `# 1. 安装 nginx 和 certbot
sudo apt install -y nginx certbot python3-certbot-nginx

# 2. 申请证书
sudo certbot --nginx -d ${domain.trim()}

# 3. 写入 nginx 配置
sudo tee /etc/nginx/sites-enabled/monitor << 'NGINX'
${nginxConf}
NGINX

# 4. 重载 nginx
sudo nginx -t && sudo systemctl reload nginx`
    : ""

  return (
    <div className="space-y-4">
      <Card className="gap-4 p-5">
        <div>
          <h3 className="text-sm font-medium">绑定域名</h3>
          <p className="mt-1 text-xs text-muted-foreground">
            填入你的域名，面板生成 nginx 反代配置。复制命令到服务器上执行，即可用域名 HTTPS 访问面板。
          </p>
        </div>
        {alreadyBound && (
          <div className="rounded-lg p-3 text-sm" style={{ background: "#1a2e1a", color: "#4ade80" }}>
            当前已通过域名 <b>{currentHost}</b> 访问，无需重复绑定。
          </div>
        )}
        <Field label="域名" hint="如 panel.example.com，需先解析到本机 IP">
          <Input
            value={domain}
            onChange={(e) => setDomain(e.target.value)}
            placeholder="panel.example.com"
          />
        </Field>
      </Card>

      {domain.trim() && (
        <>
          <Card className="gap-4 p-5">
            <div className="flex items-center justify-between">
              <h3 className="text-sm font-medium">一键命令</h3>
              <Button size="sm" variant="outline" onClick={() => copy(commands)}>
                <Copy className="size-3.5" /> 复制
              </Button>
            </div>
            <pre className="overflow-x-auto rounded-md bg-muted p-3 text-xs">{commands}</pre>
            <p className="text-xs text-muted-foreground">
              在服务器上以 root 执行以上命令。hub 保持监听 127.0.0.1:28080，无需暴露到公网。
            </p>
          </Card>

          <Card className="gap-4 p-5">
            <div className="flex items-center justify-between">
              <h3 className="text-sm font-medium">nginx 配置预览</h3>
              <Button size="sm" variant="outline" onClick={() => copy(nginxConf)}>
                <Copy className="size-3.5" /> 复制
              </Button>
            </div>
            <pre className="overflow-x-auto rounded-md bg-muted p-3 text-xs">{nginxConf}</pre>
          </Card>
        </>
      )}
    </div>
  )
}
