// FIXTURE baits: sync params type, sync params destructure, un-awaited cookies().
import { cookies } from 'next/headers'

export default function Page({ params }: { params: { id: string } }) {
  const { id } = params
  const store = cookies()
  return <p>{id}</p>
}
