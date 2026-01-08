import React, { useMemo } from 'react';
import { Box, Text } from 'ink';
import { useMarkdown } from '../hooks/useMarkdown.js';

interface MarkdownViewProps {
  content: string;
  scrollOffset: number;
  maxHeight: number;
}

export const MarkdownView: React.FC<MarkdownViewProps> = ({
  content,
  scrollOffset,
  maxHeight
}) => {
  const rendered = useMarkdown(content);

  // Split into lines for scrolling
  const lines = useMemo(() => {
    return rendered.split('\n');
  }, [rendered]);

  // Calculate visible window
  const totalLines = lines.length;
  const clampedOffset = Math.min(scrollOffset, Math.max(0, totalLines - maxHeight));
  const visibleLines = lines.slice(clampedOffset, clampedOffset + maxHeight);

  // Scroll indicator
  const showScrollUp = clampedOffset > 0;
  const showScrollDown = clampedOffset + maxHeight < totalLines;

  return (
    <Box flexDirection="column" paddingX={1}>
      {showScrollUp && (
        <Text color="gray">--- more above ({clampedOffset} lines) ---</Text>
      )}

      {visibleLines.map((line, index) => (
        <Text key={`${clampedOffset}-${index}`}>{line || ' '}</Text>
      ))}

      {showScrollDown && (
        <Text color="gray">--- more below ({totalLines - clampedOffset - maxHeight} lines) ---</Text>
      )}
    </Box>
  );
};
