// Near-miss: a page that renders a client leaf without becoming one itself.
// The directive belongs on Editor, not on the route file.
import { Editor } from '../ui/editor'

export default function Page() {
  return <Editor />
}
