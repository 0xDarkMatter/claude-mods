// Correct async params, plus an unrelated object literal that happens to carry
// a `params` key - the classic false-positive bait for a naive regex.
import { track } from '@/lib/analytics'

export default async function Page(props: PageProps<'/shop/[slug]'>) {
  const { slug } = await props.params
  const query = await props.searchParams
  track('view', { params: { slug }, searchParams: { q: query.q } })
  return <article>{slug}</article>
}
