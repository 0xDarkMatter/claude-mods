---
name: tool-discovery
description: Discover the right library or tool for any task. Maps common needs to battle-tested solutions.
triggers:
  - library for
  - tool for
  - how to parse
  - how to process
  - PDF, Excel, images, audio, video
  - OCR, crypto, chess, ML
  - parsing, scraping, database
  - scientific computing, bioinformatics
  - network analysis, data extraction
---

# Tool Discovery

Find the right library or tool for your task instead of implementing from scratch.

## When to Use

This skill activates when you need to:
- Parse file formats (PDF, Excel, images, audio, video)
- Process data (JSON, YAML, CSV, XML)
- Implement domain algorithms (crypto, chess, ML)
- Extract information (OCR, web scraping, data mining)
- Work with specialized domains (scientific, bioinformatics, network)

## How to Use

1. **Check reference.md** for authoritative recommendations
2. **Verify availability**: `which <tool>` or `pip list | grep <keyword>`
3. **Use the recommended tool** instead of manual implementation

## Why This Matters

- Your manual implementation WILL have bugs
- Battle-tested libraries are proven by thousands of users
- If you can describe what you need in 2-3 words, a tool almost certainly exists

## Example Queries

| Need | Say | Get |
|------|-----|-----|
| Read PDF | "PDF parser" | PyMuPDF, pdfplumber |
| Extract text from images | "image OCR" | tesseract, paddleocr |
| Parse Excel | "Excel reader" | openpyxl, pandas |
| Process audio | "audio processing" | librosa, pydub |
| Chess engine | "chess library" | python-chess |
| Scientific computing | "matrix operations" | numpy, scipy |

## Protocol

```
1. User asks about library/tool for X
2. INVOKE this skill
3. READ reference.md for recommendations
4. VERIFY tool is available (`which`, `pip list`)
5. USE recommended tool
6. NEVER implement from scratch what exists
```

## Anti-Patterns

```
BAD:  "I'll parse this PDF by reading the binary"
GOOD: "Let me check reference.md for PDF tools"

BAD:  "I'll analyze this image pixel by pixel"
GOOD: "Let me use PIL/OpenCV for image processing"

BAD:  "I'll write a JSON parser"
GOOD: "I'll use the built-in json module"
```

## See Also

- `reference.md` - Full library reference by category
