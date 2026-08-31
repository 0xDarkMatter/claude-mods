// The documented "read runtime data outside, pass the value in" pattern:
// an uncached reader and a cached consumer living in the SAME module.
import { cookies } from 'next/headers'
import { cacheLife } from 'next/cache'

export async function getSessionId() {
  const store = await cookies()
  return store.get('session')?.value ?? null
}

export async function getDashboard(sessionId: string | null) {
  'use cache'
  cacheLife('hours')
  return fetchDashboard(sessionId)
}
