declare module 'marked-terminal' {
  import { MarkedExtension } from 'marked';

  interface MarkedTerminalOptions {
    code?: (code: string) => string;
    blockquote?: (quote: string) => string;
    html?: (html: string) => string;
    heading?: (text: string, level: number) => string;
    firstHeading?: (text: string) => string;
    hr?: () => string;
    listitem?: (text: string) => string;
    list?: (body: string, ordered: boolean) => string;
    table?: (header: string, body: string) => string;
    paragraph?: (text: string) => string;
    strong?: (text: string) => string;
    em?: (text: string) => string;
    codespan?: (code: string) => string;
    del?: (text: string) => string;
    link?: (href: string, title: string, text: string) => string;
    href?: (href: string) => string;
    tableOptions?: {
      chars?: Record<string, string>;
    };
    reflowText?: boolean;
    width?: number;
    showSectionPrefix?: boolean;
    tab?: number;
  }

  export function markedTerminal(options?: MarkedTerminalOptions): MarkedExtension;
}
