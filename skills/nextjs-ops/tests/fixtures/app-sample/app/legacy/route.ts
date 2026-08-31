// FIXTURE bait: the deprecated edge runtime opt-in.
export const runtime = 'edge'

export async function GET() {
  return Response.json({ ok: true })
}
