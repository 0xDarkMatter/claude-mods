'use cache'
// FIXTURE baits: request API and non-determinism inside a file-level cache scope.
import { headers } from 'next/headers'

export async function getBanner() {
  const h = await headers()
  return { host: h.get('host'), nonce: Math.random() }
}
