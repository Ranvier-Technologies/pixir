# Pixir Site

Astro static marketing site for `pixir.dev`.

## Local Commands

```bash
pnpm install
pnpm test
pnpm check
pnpm build
pnpm preview
```

## WebMCP

The site registers a small read-only tool catalog when `document.modelContext`
exists (WebMCP draft, page-side `registerTool`). Ordinary browsers without that
API are a no-op. This is not a backend MCP server and does not change the Pixir
CLI/ACP runtime.

Tools:

- `pixir.get_started`
- `pixir.preview_scope`
- `pixir.operator_primitives`

## Deployment Stance

- Deploy target: Vercel.
- Registrar and DNS: Cloudflare.
- Cloudflare records pointing to Vercel should start as DNS-only / gray cloud.
- Do not enable Cloudflare proxy / orange cloud in front of Vercel unless a later
  decision explicitly accepts the tradeoff.

## Domain Records

Configure the custom domain from Vercel first, then copy the exact DNS records Vercel
requests into Cloudflare. Do not hand-create speculative `A` or `CNAME` records before
the Vercel project exists.

The initial Vercel domain check for `pixir-site` requested these Cloudflare records:

| Type | Name | Content | Proxy status |
| --- | --- | --- | --- |
| `A` | `@` | `76.76.21.21` | DNS only |
| `A` | `www` | `76.76.21.21` | DNS only |

Keep both records gray-clouded in Cloudflare. Do not switch them to proxied/orange-cloud
unless a later decision explicitly accepts Vercel-behind-Cloudflare tradeoffs.
