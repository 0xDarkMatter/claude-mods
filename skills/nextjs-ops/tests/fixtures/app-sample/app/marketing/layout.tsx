'use client'
// FIXTURE baits: a client directive on a route file drags the segment into the
// bundle, and force-dynamic opts the whole route out of static rendering.
export const dynamic = 'force-dynamic'

export default function Layout({ children }: { children: React.ReactNode }) {
  return <section>{children}</section>
}
