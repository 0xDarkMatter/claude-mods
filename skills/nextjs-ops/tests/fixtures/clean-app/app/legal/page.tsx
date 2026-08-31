// Near-miss: force-static is correct here precisely BECAUSE nothing reads
// request data. The rule must need both halves, not just the export.
export const dynamic = 'force-static'

export default function Page() {
  return <article>Terms of service</article>
}
