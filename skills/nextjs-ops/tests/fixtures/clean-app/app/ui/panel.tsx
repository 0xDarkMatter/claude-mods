'use client'
// Public env vars and NODE_ENV are legitimate on the client. Response headers
// and the Headers constructor are not next/headers.
export function Panel() {
  const url = process.env.NEXT_PUBLIC_API_URL
  const debug = process.env.NODE_ENV !== 'production'
  const h = new Headers()
  return <div data-url={url} data-debug={String(debug)} data-h={h.get('x') ?? ''} />
}
