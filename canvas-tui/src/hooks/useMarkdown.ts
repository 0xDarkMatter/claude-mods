import { useMemo } from 'react';
import { marked } from 'marked';
import { markedTerminal } from 'marked-terminal';
import chalk from 'chalk';

// Configure marked with terminal renderer
marked.use(
  markedTerminal({
    // Colors for different elements
    code: chalk.cyan,
    blockquote: chalk.gray.italic,
    html: chalk.gray,
    heading: chalk.bold.blue,
    firstHeading: chalk.bold.blue.underline,
    hr: chalk.gray,
    listitem: chalk.white,
    list: (body: string) => body,
    table: chalk.white,
    paragraph: chalk.white,
    strong: chalk.bold,
    em: chalk.italic,
    codespan: chalk.yellow,
    del: chalk.strikethrough,
    link: chalk.blue.underline,
    href: chalk.blue.underline,

    // Table rendering
    tableOptions: {
      chars: {
        top: '-',
        'top-mid': '+',
        'top-left': '+',
        'top-right': '+',
        bottom: '-',
        'bottom-mid': '+',
        'bottom-left': '+',
        'bottom-right': '+',
        left: '|',
        'left-mid': '+',
        mid: '-',
        'mid-mid': '+',
        right: '|',
        'right-mid': '+',
        middle: '|'
      }
    },

    // Misc settings
    reflowText: true,
    width: 80,
    showSectionPrefix: false,
    tab: 2
  })
);

export function useMarkdown(content: string): string {
  return useMemo(() => {
    if (!content) return '';

    try {
      // Parse markdown to terminal-formatted string
      const rendered = marked.parse(content);
      // marked returns Promise in some configs, but sync with markedTerminal
      if (typeof rendered === 'string') {
        return rendered.trim();
      }
      return content; // Fallback to raw content
    } catch (err) {
      console.error('Markdown parse error:', err);
      return content; // Return raw content on error
    }
  }, [content]);
}
