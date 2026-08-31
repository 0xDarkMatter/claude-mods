'use server'
// A correctly guarded action - but the guard comes from a project DAL with a
// house name, not from a package literally called "auth".
import { requireOwner } from '@/lib/guard'
import { revalidateTag } from 'next/cache'

export async function completeItem(itemId: string) {
  const item = await requireOwner(itemId)
  await db.item.update({ where: { id: item.id }, data: { completed: true } })
  revalidateTag('items', 'max')
}
