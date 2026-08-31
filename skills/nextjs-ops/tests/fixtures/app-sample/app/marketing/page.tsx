// FIXTURE baits: force-static silently empties the cookie read, and the
// force-dynamic sibling below is the cargo-culted "fix the stale page" export.
import { cookies } from 'next/headers'

export const dynamic = 'force-static'

export default async function Page() {
  const store = await cookies()
  return <p>{store.get('theme')?.value}</p>
}
