'use server'
// FIXTURE baits: no auth check anywhere, and the deprecated single-arg revalidateTag.
import { revalidateTag } from 'next/cache'

export async function deleteEverything(id: string) {
  await db.items.delete({ where: { id } })
  revalidateTag('items')
}
