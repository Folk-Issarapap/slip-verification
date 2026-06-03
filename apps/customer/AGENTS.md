# Admin Codex Instructions

These instructions apply under `apps/admin`.

## Stack

Admin is a vinext app running on Cloudflare Workers. It is not standard Next.js.
Before changing Next.js behavior, read the relevant docs in
`node_modules/next/dist/docs/` and heed deprecation notices.

## Structure

```text
app/
  (admin)/
    page.tsx
    <feature>/
      page.tsx
      _actions/
      _components/
      _lib/
  (auth)/login/
  auth/callback/
  layout.tsx
components/
lib/
  api-client.ts
  auth-client.ts
  providers.tsx
messages/
```

## vinext Rules

- Do not add `@vitejs/plugin-rsc`; vinext registers it.
- Do not add `@cloudflare/vite-plugin` for dev; it causes 404s.
- Use `@tailwindcss/vite`, not `@tailwindcss/postcss`.
- Keep `cloudflare:workers` in `build.rollupOptions.external`.
- Use `cacheTag` and `cacheLife`, not `unstable_*` names.
- Fonts must use the repo's proxy-safe loader pattern. For JetBrains Mono, use
  `createFontLoader("JetBrains Mono")`; direct `JetBrains_Mono` can fail vinext
  parsing.
- Keep font imports near the top of layout files when present; sorters can break
  the parser.
- Static assets go in `apps/admin/public/`, except `app/favicon.ico`.

## Static Asset Proxy

`proxy.ts` redirects unauthenticated visitors to `/login`. Any public asset must
be allowed in the matcher or the browser may receive login HTML instead of the
asset.

Symptoms:

- Existing public file returns a redirect to `/login`.
- Favicon does not update after hard refresh.
- Manifest/PWA prompt silently fails.

## API Client

```tsx
import { api } from "@/lib/api-client"

const res = await api.v1.products.$get({ query: { page: 1, limit: 20 } })
```

The client is typed from `AdminAppType` exported by `apps/api`.

## Data Fetching

`_actions` files are client-side API wrappers, not server actions.

Reads throw on failure so React Query handles errors. Mutations return
`{ error }` or `{ success, data }`.

```tsx
const res = await api.v1.products.$get({ query })
if (!res.ok) throw new Error("Failed")

const mutation = await api.v1.products.$post({ json: data })
if (!mutation.ok) return { error: "Failed" }
return { success: true, data: (await mutation.json()).data }
```

Use React Query invalidation only:

```tsx
await queryClient.invalidateQueries({ queryKey: ["products"] })
```

Do not use `revalidatePath`.

## i18n

Every user-facing string must use `next-intl` and the admin message files
(`messages/en.json`, `messages/th.json`).

```tsx
const t = useTranslations("products")
const tc = useTranslations("common")
t("dialog.delete.title", { name })
```

Reuse existing common/status/nav keys when vocabulary is generic.

## Forms

Use react-hook-form, Zod resolver, and Field primitives.

```tsx
const form = useForm({ resolver: zodResolver(schema), defaultValues })
const { control, handleSubmit, formState } = form
```

- Native inputs can use `register`.
- Non-native inputs use `Controller`.
- Do not use `setValue(... as Type, { shouldDirty: true })` for widget inputs.
- Complex forms use Sheet. Simple confirmations use Dialog.
- High-impact saves should show AlertDialog with `ChangeDiff`.
- Use sonner toasts; one toast per user action.

## Formatting

Use `AppCurrency`, `AppDateTime`, `useFormatter`, or `useFormatCurrency`.
Do not hand-format THB amounts or timestamps in UI code.

## Card And Layout Rules

- Top-level main-column sections use Card containment for editable settings and
  read-only summaries.
- `Card` defaults to sectioned chrome: header border, content vertical padding,
  footer border with muted surface, and footer action gap. Do not pass
  `className` to Card primitives.
- Use `Card size="sm"` for sidebar context cards. Use `DataGridCard` for
  DataGrid surfaces. Use `KpiStripCard` for KPI/stat strips.
- Never override `px-*`, `pl-*`, or `pr-*` on `CardHeader`, `CardContent`, or
  `CardFooter`. Use parent `size="sm"` or update the primitive.
- Never place DataGrid inside CardContent; CardContent is intentionally padded.
- Never place DataGrid inside a raw Card; render it directly inside
  `DataGridCard`.
- CardHeader direct children should be CardTitle, CardDescription, and
  CardAction. CardTitle is heading text only; supporting text belongs in
  CardDescription; controls, badges, menus, and compact status belong in
  CardAction.
- CardContent does not own vertical gaps. If content needs rhythm, wrap it in an
  inner `<div className="space-y-4">`.
- Do not add `text-sm`, `text-xs`, or custom size classes inside Card primitive
  subtrees; primitive parents own sizing.
- Admin pages cap spacing at `space-y-4` / `gap-4`.
- Do not wrap a single `Item variant="outline"` in a Card.
- If a `SectionList` child may return null, that child root must be `Section` to
  avoid orphan separators/gaps.

Canonical patterns:

- Section card: `<section><Card><CardHeader><CardTitle /></CardHeader><CardContent /></Card>`.
- Sidebar context card: `<Card size="sm">`.
- KPI strip: `<KpiStripCard>` plus divided tile grid.
- DataGrid containment: `<DataGridCard>` and direct `<DataGrid variant="card">`.

## Timeline And Activity

- `Timeline` is the low-level visual primitive for ordered dots, lines, dates,
  titles, and content. Do not add domain assumptions there.
- `LifecycleTimeline` is for one entity's state/milestone history: created,
  processing, succeeded, failed, cancelled, completed. Use it when the question
  is "what state did this object go through?"
- `ActivityFeed` is for compact audit/log/GL previews. Use it when the question
  is "what happened around this object?"
- Use DataGrid instead of ActivityFeed when users need columns, filters, sorting,
  pagination, or expandable audit details.
- Use `Event` for stored/emitted domain rows such as `settlement_events` or
  `webhook_events`; render them with `LifecycleTimeline` only when the UI is
  explaining object state progression.

## Lists And Tables

- Index/list pages use full `DataGrid` with URL state, toolbar, and pagination.
- Potentially unbounded previews use `DataGrid variant="card" hideFooter`.
- Bounded detail sub-collections use `ItemGroup` and `Item`.
- Pickers that can exceed 100 records must use searchable Combobox with
  debounced server-side `q=` search. Do not raise API limits past 100.
- Reference picker pattern: `components/pickers/account-picker.tsx`.

DataGrid cell conventions:

- IDs, invoice IDs, and references use `CopyIconButton`, not pill-like copy
  chips.
- Customer column shows name plus `customer_reference_number` mono subtitle, not
  email.
- Payment methods use `PaymentMethodBadge`.

## Detail Chrome

Card-based detail/create chrome is the current standard across detail pages.

- Breadcrumb owns back navigation; do not add `PageHeroBack`.
- `AvatarBadge` is only for staff/users and means online presence, not status.
- Tab strips scroll on overflow, are capped at seven visible tabs, and move
  config tabs to a sidebar Manage Card when needed.

## Design Tokens

- Use semantic tokens from `packages/ui/globals.css`: `success`, `info`,
  `warning`, `danger`, and foreground partners.
- Avoid hardcoded Tailwind color palettes such as `text-emerald-*` in product UI.
- No hex colors in TSX or SVG attributes.
- No arbitrary text sizes such as `text-[12.5px]`; use the Tailwind scale.
- Visual polish should stay restrained: subtle alpha, minimal shadows, and both
  light/dark mode checks.

## Icons

- Do not put icons in headings.
- Use lucide icons inside buttons where available.
- Edit/settings actions use Cog, not Pencil.

## Badges

- Status: active -> success; draft/archived -> neutral.
- Roles: admin -> danger; editor -> info; viewer -> neutral.
- Actions: POST -> success; PUT -> info; PATCH -> warning; DELETE -> danger.

## Adding A Page

1. Create `app/(admin)/<feature>/page.tsx`.
2. Add `_actions`, `_components`, and `_lib` for feature-specific code.
3. Use the typed `api` client.
4. Add navigation in the sidebar.
5. Add/extend `messages/en.json` and `messages/th.json`.
