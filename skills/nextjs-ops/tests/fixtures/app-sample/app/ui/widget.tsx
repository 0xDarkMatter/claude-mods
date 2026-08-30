'use client'
// FIXTURE baits: a secret env var and a server-only import on the client side.
import 'server-only'

export function Widget() {
  return <span data-key={process.env.STRIPE_SECRET_KEY} />
}
