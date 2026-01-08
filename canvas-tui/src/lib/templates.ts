export interface ContentTemplate {
  name: string;
  description: string;
  template: string;
}

export const templates: Record<string, ContentTemplate> = {
  email: {
    name: 'Email',
    description: 'Professional email format with subject, greeting, and signature',
    template: `# Email Draft

\`\`\`
To:
CC:
BCC:
Subject:
\`\`\`

---

Hi [Name],

[Your message here]

Best regards,
[Your name]

---
*Draft started: ${new Date().toLocaleString()}*
`
  },

  message: {
    name: 'Message',
    description: 'Casual message format for Slack, Teams, or Discord',
    template: `# Message Draft

**To:** #channel / @person

---

[Your message here]

---
*Draft started: ${new Date().toLocaleString()}*
`
  },

  doc: {
    name: 'Document',
    description: 'Structured markdown document with sections',
    template: `# Document Title

## Overview

[Brief description of the document's purpose]

## Details

[Main content here]

## Summary

[Key takeaways]

---
*Draft started: ${new Date().toLocaleString()}*
`
  }
};

/**
 * Get a template by type, with current timestamp
 */
export function getTemplate(type: keyof typeof templates): string {
  const template = templates[type];
  if (!template) {
    return templates.doc.template;
  }
  // Replace timestamp placeholder with current time
  return template.template.replace(
    /\$\{new Date\(\)\.toLocaleString\(\)\}/g,
    new Date().toLocaleString()
  );
}

/**
 * List available template types
 */
export function listTemplates(): Array<{ type: string; name: string; description: string }> {
  return Object.entries(templates).map(([type, template]) => ({
    type,
    name: template.name,
    description: template.description
  }));
}
