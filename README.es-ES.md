```
 ██████╗██╗      █████╗ ██╗   ██╗██████╗ ███████╗    ███╗   ███╗ ██████╗ ██████╗ ███████╗
██╔════╝██║     ██╔══██╗██║   ██║██╔══██╗██╔════╝    ████╗ ████║██╔═══██╗██╔══██╗██╔════╝
██║     ██║     ███████║██║   ██║██║  ██║█████╗      ██╔████╔██║██║   ██║██║  ██║███████╗
██║     ██║     ██╔══██║██║   ██║██║  ██║██╔══╝      ██║╚██╔╝██║██║   ██║██║  ██║╚════██║
╚██████╗███████╗██║  ██║╚██████╔╝██████╔╝███████╗    ██║ ╚═╝ ██║╚██████╔╝██████╔╝███████║
 ╚═════╝╚══════╝╚═╝  ╚═╝ ╚═════╝ ╚═════╝ ╚══════╝    ╚═╝     ╚═╝ ╚═════╝ ╚═════╝ ╚══════╝
```

[![Claude Code](https://img.shields.io/badge/Claude%20Code-plugin-blueviolet?logo=anthropic)](https://docs.anthropic.com/en/docs/claude-code)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

> *Un kit de herramientas de extensión integral que transforma Claude Code en una potencia de desarrollo especializada.*

**claude-mods** es un plugin listo para producción que extiende Claude Code con 102 habilidades especializadas, 3 agentes expertos, 13 estilos de salida, 13 hooks y herramientas de CLI modernas diseñadas para flujos de trabajo de desarrollo del mundo real. Ya sea que estés depurando hooks de React, optimizando consultas de PostgreSQL o construyendo aplicaciones CLI para producción, este kit dota a Claude de la experiencia de dominio y el conocimiento procedimental para trabajar a nivel experto en múltiples stacks tecnológicos.

Construido sobre la [especificación de Agent Skills](https://agentskills.io/specification) (un estándar abierto respaldado por Anthropic, Vercel, Google, Microsoft y más de 40 plataformas de agentes), claude-mods llena vacíos críticos en las capacidades de Claude Code: estado de sesión persistente que sobrevive entre máquinas, conocimiento experto bajo demanda para dominios especializados, herramientas de CLI modernas eficientes en tokens (de 10 a 100 veces más rápidas que las alternativas tradicionales) y patrones de flujo de trabajo probados para TDD, revisión de código y desarrollo de funcionalidades. El kit implementa los [patrones recomendados por Anthropic para agentes de larga ejecución](https://www.anthropic.com/engineering/effective-harnesses-for-long-running-agents), asegurando que tu contexto de desarrollo nunca desaparezca cuando las sesiones terminen.

Desde patrones asíncronos de Python hasta modelos de propiedad de Rust, desde despliegues de AWS Fargate hasta desarrollo de Craft CMS; claude-mods proporciona el conocimiento y las herramientas especializadas que transforman a Claude de un asistente de propósito general en un experto de dominio que entiende tu stack, recuerda tu flujo de trabajo y entrega código de producción.

**3 agentes. 102 habilidades. 13 estilos. 13 hooks. 14 reglas. Una instalación.**

## Actualizaciones Recientes

**v3.6.0** (Julio 2026)
- 🎨 **Habilidad `svg-brand-tint-ops`** — un estudio de SVG en el navegador sin dependencias. Recolorea cualquier SVG a una paleta de marca mediante un sistema **tri-tono** basado en tokens (`feColorMatrix` desaturate → `feComponentTransfer` grey-ramp remap → CSS-filter bake consciente del tema), además de un **vectorizador** raster desde cero (PNG → SVG) basado en una **etapa de geometría Potrace-paper** — rectitud de tubo de tolerancia, polígono óptimo por penalización-DP, ajuste de vértice sub-píxel y análisis de esquina alphamax, reimplementado a partir del artículo de Selinger 2003 publicado libremente (sin código GPL) — sobre marching-squares de campo suave con **manejo de paleta consciente de alfa** (de-blending de mate, eliminación de flecos anti-alias, veto de mezcla) que mantiene nítidos los logotipos de marca de color plano. Modos de trazo B&N / posterizado / color, un stack de filtros fotográficos, Google Fonts curadas en `<text>` de SVG, inspección de elementos al pasar el mouse, división antes/después y paleta desde imagen. Incluye un servidor estático sin dependencias de ~90 líneas (`scripts/server.mjs`), una CLI de trazo headless (`scripts/trace.mjs`) que comparte un único motor canónico con la herramienta del navegador (`assets/trace-core.mjs`, sin derivaciones), una referencia de matemáticas de color + trazo + horneado de tema, y una suite de pruebas offline de 22 aserciones.

**v3.5.0** (Julio 2026)
- 📐 **Habilidad `isometric-ops`** — activos ilustrativos isométricos de extremo a extremo: creación, refinamiento, composición y exportación para sitios web y juegos. **14 referencias** anclan la matemática exacta de la proyección (isométrica real de 30° vs **dimétrica 2:1 de 26.565°** — el error de etiqueta que rompe los tilesets — con cada constante derivada y verificada por máquina mediante un verificador de obsolescencia §7), transformaciones de coordenadas + doctrina de profundidad y ordenación-y (y-sort), la disciplina de especificación de tiles, generación de SVG/CSS/three.js, flujo de trabajo de pixel-art de Aseprite, rigs orto duales de Blender (dimétrica de 60° vs iso real de 54.736°), tilemaps de motores (Godot 4 / Unity / Phaser 3) y el pipeline de IA completo — generación con Recraft/Midjourney/Flux+LoRA bajo **control de estructura de profundidad/MLSD de ControlNet**, escalado + escaleras de vectorización, y disciplina de licencias que verifica las cláusulas de entrenamiento de IA. Scripts: `iso-math.py` (constantes/transformaciones/generador de rejillas), `tile-validate.py` (QA de tiles de IA: halo, sangrado, ancla, paleta), `sheet-pack.py` (spritesheet + atlas). Encabezado por **iso-studio** — un compositor de escenas en el navegador sin dependencias con ajuste a rejilla, y-sort consciente de la huella, paletas de control acopladas, exportación PNG/SVG/scene-JSON y un modo de bloqueo que exporta **mapas de profundidad + lineart directamente hacia el condicionamiento de ControlNet** — construido junto con la habilidad y extraído a [su propio repositorio](https://github.com/0xDarkMatter/iso-studio) (una app con hoja de ruta y librería de activos es un producto, no un recurso de habilidad).

**v3.4.0** (Junio 2026)
- 📊 **Habilidad `r-ops`** — la primera habilidad de ciencia de datos del conjunto: una referencia basada en tidyverse y mejores prácticas actuales para R moderno (2024+). `SKILL.md` dirige un flujo de importación → tidy → transformación → visualización → modelado → comunicación a través de **9 archivos de referencia (~115 KB)** — tidyverse-core, import-io, strings-dates-factors, visualization, iteration-functional, modeling-stats, data-table, time-series, workflow-tooling. Lidera con modismos actuales (native `|>`, dplyr `.by=`, la lambda `\(x)`, `across()`, `list_rbind`, `slice_*`, tidymodels, el stack tidyverts `tsibble`/`fable`, Quarto + renv) y menciona base R / `data.table` donde estos son superiores. Incluye un autotest offline de 43 aserciones más un verificador de obsolescencia §7 `check-r-facts.py` (`--offline` aserta que cada paquete de CRAN catalogado siga nombrándose en la prosa y que la nota de vigencia lleve el año; `--live` resuelve cada paquete en CRAN) para que la afirmación de stack moderno sea **impuesta por máquina, no solo afirmada**. Recuperado y actualizado del antiguo PR #6 (que también duplicaba la defensa de la cadena de suministro ya implementada), reinstalado limpiamente desde el `main` actual.

**v3.3.0** (Junio 2026)
- 🔁 **Habilidad `loop-ops`** — la disciplina de diseño de *bucle externo* (outer-loop): cómo diseñar y ejecutar **de forma segura** bucles de agentes autónomos y programados — la capa de orquestación por encima de [`iterate`](skills/iterate/) (que impulsa una sola ejecución interna). Su columna vertebral es una **escalera de riesgo de autonomía gradual** (L1 reporte → L2 asistido → L3 desatendido) mapeada sobre el modelo de permisos *real* de Claude Code, por lo que un bucle solo obtiene la autoridad que ha ganado — anclada por la regla de que **un programador invoca `claude -p`, nunca una sesión que genera hijos sin restricciones**. Incluye una **morfología de 13 patrones** — `trigger` (cadencia · Canales impulsados por eventos · ejecución hasta finalización `/goal`) × `posture` (L1–L3) × `locus` (rutina conector→nube · tarea local→Desktop) — además de una columna de ESTADO/log-de-ejecución/presupuesto, coordinación de bucles múltiples y un interruptor de apagado (kill switch). Tres herramientas hacen el trabajo: **`loop-scaffold`** planta un bucle casi listo, **`loop-check`** rechaza el visto bueno en alcances ilimitados / puertas faltantes / escalada indefinida, y **`loop-estimate`** da el costo/mes consciente del almacenamiento en caché antes de comprometerse con una cadencia. Compone `fleet-worker` (generar) y `fleet-ops` (aterrizar).

**v3.2.0** (Junio 2026)
- 🤖 **Habilidad `fleet-worker`** — delega tareas de múltiples pasos que usan herramientas a *trabajadores de Claude Code headless más económicos* — un modelo de Anthropic más barato (Sonnet/Haiku) o cualquier endpoint compatible con Anthropic (ej. GLM 5.2 vía z.ai) — mientras un orquestador Opus los distribuye en paralelo y filtra sus resultados antes de que cualquier cosa aterrice. Cada trabajador es un `claude -p` real con todo el arnés de herramientas de Claude Code (Read/Write/Edit/Bash/Glob/Grep/Task) y cualquier habilidad que le asignes, pero con un cerebro más económico — aislado en su propio git worktree + `CLAUDE_CONFIG_DIR`. Incluye lanzadores bash + PowerShell, un colector de filtrado de resultados, un verificador de salud de endpoints y las recetas de traspaso de fleet-ops. fleet-worker es la capa de **generación** (spawn); [`fleet-ops`](skills/fleet-ops/) es la capa de **aterrizaje** (landing) con puerta de pruebas a la que entrega las ramas ganadoras. Agnostico al proveedor.

**v3.1.0** (Junio 2026)
- 🗺️ **Habilidad `mapbox-ops`** - Mapbox GL JS avanzado para la web (v3): marcadores SVG/canvas personalizados y pines de foto circulares, dataviz temática (coropletos, mapas de calor, símbolos proporcionales, extrusiones 3D), terreno con sombreado y curvas de nivel, cámara cinematográfica de vuelo/órbita y ciclos animados día-noche, composición de estilos (slots Estándar v3 + config, recoloración de paleta clásica, estilos de terceros), estilizado impulsado por expresiones y los errores difíciles de detectar que eliminan tus marcadores silenciosamente. 14 archivos de referencia más un verificador de alineación de marcadores headless-Playwright.
- 📐 **Protocolo de Creación de Habilidades** - [docs/SKILL-CREATION-PROTOCOL.md](docs/SKILL-CREATION-PROTOCOL.md), el documento canónico de "cómo construir una habilidad de claude-mods": un ciclo de vida secuenciado (¿está justificada? → frontmatter → cuerpo → recursos → pruebas → conexión al repo → envío) que cita la documentación de la capa propietaria en lugar de repetirla, con una tabla de precedencia para cuando discrepen.
- 📋 **Habilidad `adr-ops`** - Architecture Decision Records (Registros de Decisiones de Arquitectura) como flujo de trabajo entre proyectos. Los ADR son memoria de proyecto de solo anexo: capturan el *porqué* un sistema tomó su forma — las alternativas sopesadas, las restricciones aceptadas — para que un futuro mantenedor recupere el razonamiento sin hacer arqueología en el historial de git o logs de chat. Aporta la regla de cuándo escribir, el formato canónico, el ciclo de vida propuesto→aceptado→superado y la disciplina de superación de solo anexo, con cinco herramientas de Protocolo-de-Recursos (init / new / index / consulta de `touches` / lint) y una suite de 72 aserciones.
- 📚 **Habilidad `okf-ops`** - evalúa, valida y adopta el [Open Knowledge Format](https://cloud.google.com/blog/products/data-analytics/how-the-open-knowledge-format-can-improve-data-sharing/) — la especificación neutral de proveedor de Google Cloud (v0.1, Apache-2.0) para empaquetar el conocimiento organizacional como un directorio de archivos markdown con frontmatter YAML que los agentes de IA pueden consultar sin una plataforma o SDK. Un escáner de preparación de solo lectura encuentra buenos candidatos de adopción en muchos repositorios; un validador de conformidad (`--strict` para CI) verifica un paquete. Alcance honesto integrado — OKF es un borrador v0.1, adoptar por repositorio.
- 📦 **Habilidad `pypi-ops`** - publica paquetes de Python en PyPI al estilo de 2026: Publicación Confiable OIDC con atestaciones PEP 740 vía `gh-action-pypi-publish`, no tokens de API almacenados. Configuración de primer envío para publicadores pendientes, la escalera de fallos `invalid-publisher` / "ya existe", simulacros de TestPyPI, puertas de aprobación de entorno de lanzamiento, `uv publish` / `twine` local, y una auditoría de federación OIDC obsoleta.
- 🔍 **Auditoría de salud de repo github-ops** — conoce la postura de seguridad de un repo de un vistazo, sin salir de la terminal. Un auditor de **solo lectura** verifica los controles que realmente importan (Dependabot, escaneo de secretos + código, reporte de vulnerabilidades privadas, `SECURITY.md`, protección de ramas) con severidad consciente de la visibilidad, señala problemas abiertos obsoletos como advertencia pre-push, y lo resume todo en una **`repo-scorecard`** puntuada que califica un solo repo — o una `--org` completa — en una sola pasada. Emite los comandos exactos de corrección y nunca toca tu repo, para que tú decidas qué aplicar.

**v3.0.0** (Junio 2026)
- **Reestructuración centrada en Habilidades** - *Cambio disruptivo:* la capa de agentes expertos se redujo de 23 a 3. Según la guía de Anthropic, el conocimiento pertenece a las habilidades (revelación progresiva, fuente única de verdad) y los subagentes se reservan para el aislamiento del contexto — por lo que *todos* los agentes de conocimiento de dominio se convirtieron en habilidades `-ops` (los 11 expertos en lenguaje/framework → sus gemelos; cypress/cloudflare/bash/craftcms/payloadcms/asus-router → nuevas habilidades; claude-architect/aws-fargate se fusionaron en habilidades existentes). Los 3 agentes restantes son roles puros de aislamiento/trabajador: `git-agent` (commits/PRs en segundo plano), `firecrawl-expert` (raspidos multi-página ruidosos), `project-organizer` (reestructuración masiva). El despacho de habilidades ahora dirige agentes de `propósito-general` que precargan las referencias de la habilidad.
- **Habilidad `claude-code-ops`** - la maquinaria de Claude Code misma en una sola habilidad: el catálogo completo de 30 eventos de hook con contratos JSON de stdin/stdout por evento y los cinco tipos de hook; la especificación actual de frontmatter de `SKILL.md` (`when_to_use`, `context: fork`, hooks con alcance de habilidad); una referencia headless/CLI (`claude -p`, `stream-json`, salida estructurada, agentes en segundo plano); y árboles de decisión de depuración de extensiones. Fusiona y reconstruye las antiguas habilidades claude-code-debug/-headless/-hooks frente a la documentación viva de junio-2026 - el contrato de hook `$TOOL_INPUT` obsoleto ha desaparecido (JSON de stdin es el actual), con la guía de arquitectura de extensiones de claude-architect integrada.
- **Habilidad `claude-api-ops`** - construir aplicaciones *sobre* Claude: la API de Messages, bucles de uso de herramientas, almacenamiento en caché de prompts, salidas estructuradas (`output_config.format`), la API de Batches, pensamiento extendido/adaptativo, una tabla actual de selección de modelos + precios, y el SDK de Agentes de Claude (Python + TypeScript). Incluye una lista de verificación de optimización de costos y un verificador `check-model-table.py` que señala derivaciones de modelo/precio frente a la API viva.
- **Habilidad `playwright-ops`** - pruebas de extremo a extremo bien hechas: jerarquía de selectores basada en roles y aserciones web-first (sin esperas manuales), fixtures / patrones de Page-Object, mocking de red y reproducción de HAR, auth de `storageState`, sharding y paralelismo, regresión visual, y un manual de caza de fallos intermitentes (flakes) con un clasificador `triage-flakes.py`. Incluye una plantilla de `playwright.config.ts` para producción.
- **Habilidad `terraform-ops`** - infraestructura como código con Terraform/OpenTofu: diseño de directorio por entorno, gestión de estado remoto (`moved`/`import`/`removed`, detección de deriva, disciplina de cirugía de estado), composición de módulos, secretos de solo escritura y `terraform test` nativo. Incluye una plantilla de flujo de trabajo de GitHub Actions de plan-on-PR / apply-on-merge mediante OIDC y un verificador `check-action-refs.sh` (la comprobación que habría detectado el error de etiqueta de `trivy-action`).
- **Habilidad `ffmpeg-ops`** - operaciones de ffmpeg/ffprobe basadas en sondeo previo: un libro de cocina de ~30 comandos con una tabla de errores comunes (semántica de búsqueda/keyframe, `yuv420p`+`faststart`, comillas, VFR), edición impulsada por EDL (edición-como-código - activo de esquema + `cut-from-edl.py`, simulacro por defecto), gradación de color `.cube`/Hald-CLUT con un catálogo de looks de ~40 recetas (películas incl. halación de CineStill, gradaciones cinematográficas firmadas, una familia de mapas de tono de 18 variantes) y un selector donde el humano elige la gradación, puertas de calidad VMAF/SSIM, loudnorm de dos pasadas, codificación de prueba de codificadores de hardware (listado ≠ funcionando), autoría de capítulos, compresión de tamaño objetivo, sprites de vista previa de scrubbing, preparación para Whisper/STT, y un `--doctor` de sondeo que empareja cada peligro con su comando de corrección exacto. 19 referencias, un verificador de obsolescencia §7 `verify-commands.sh`, suite de autotests de 107 aserciones sobre activos sintetizados de lavfi.
- **Habilidad `ytdlp-ops`** - la capa de adquisición de medios yt-dlp que alimenta a `ffmpeg-ops`: doctrina de selección de formato (ordenar `-S` sobre filtros `-f`, selección de códec que evita re-transcodificaciones), recorte en la descarga (`--download-sections`), extracción de audio solo STT (copia de flujo `-x`), sincronizaciones de canal incrementales (el patrón cron `--break-on-existing --lazy-playlist`), cookies/auth (`--cookies-from-browser`, la advertencia de Chrome 127+ en Windows), SponsorBlock, captura de livestreams/estrenos, y una escalera de triaje de fallos (nsig/403/429/geo, bloqueos de huella TLS → `--impersonate`, la clase EJS no-JS-runtime). 6 referencias, un verificador §7 `check-ytdlp-version.sh` (señala una instalación con más de 60 días de retraso respecto al último lanzamiento, o un flag principal que desapareció de `--help`), autotest offline de 28 aserciones.
- **Guardias de seguridad en vivo, cero configuración manual** - `config-change-guard.sh` escanea los archivos de configuración de Claude en busca de IOC de persistencia de gusanos en el momento en que se editan; `worktree-guard.sh` impone mecánicamente los límites del worktree. El archivo `hooks/hooks.json` a nivel de plugin conecta automáticamente el conjunto de seguridad durante la instalación.
- **Protocolo de Recursos de Habilidades** - un estándar de construcción para scripts y activos de habilidades ([docs/SKILL-RESOURCE-PROTOCOL.md](docs/SKILL-RESOURCE-PROTOCOL.md)), encabezado por el patrón de verificador de obsolescencia: las comprobaciones offline filtran la CI de los PR, las comprobaciones de deriva en vivo se ejecutan semanalmente sin bloquear nunca un PR. Se incluyen cuatro verificadores.
- **fleet-ops v2** - reposicionado como disciplina de aterrizaje (cola secuencial, merge con puerta de pruebas, limpieza pre-aterrizaje, reversión de un solo disparo, nuevo `fleet track`) sobre equipos de agentes nativos y agentes en segundo plano, que ahora gestionan la generación de sesiones.
- **Documentación que no se pudre** - nuevo `CHANGELOG.md`; una puerta de deriva de docs en CI falla la compilación cuando los recuentos del README divergen del disco o un enlace desaparece; la suite conductual de cada habilidad se ejecuta en CI; `/save` + `/sync` reposicionados como estado portátil y compartible en equipo junto con la auto-memoria nativa.

**v2.10.0** (Mayo 2026)
- 🕵️ **Habilidad `prompt-injection-defense`** - hermana de integridad de instrucciones de `supply-chain-defense`: defiende la superficie de contexto del agente contra contenido adversarial donde lo que ve un revisor difiere de lo que lee el modelo. `scan-hidden-unicode.py` detecta reordenamiento bidi/Trojan-Source, contrabando de bloques de etiquetas `U+E0000` ASCII, texto de ancho cero y (`--strict`) homóglifos — con lista blanca de emojis para evitar falsos positivos en cada README; `sanitize-content.py` los elimina del contenido no confiable antes de la ingesta (fiel a los bytes, idempotente). Desplegado como guardianes silenciosos en los límites de confianza: un hook de SessionStart escanea los archivos de instrucciones del proyecto al iniciar, una puerta de pre-commit de git bloquea Unicode oculto `crítico` para que no entre al repo, y `rules/prompt-injection.md` impulsa el escaneo-al-entrar / saneamiento-al-ingestar. Catálogo de codepoints + 2 referencias + suite offline de 18 aserciones.

**v2.9.0** (Mayo 2026)
- 🛡️ **Habilidad `supply-chain-defense`** - defensa basada en comportamiento contra la campaña de gusanos de npm/PyPI/Composer de 2026 (Shai-Hulud) que `npm audit` pierde en la ventana entre la publicación y el aviso — el hermano proactivo de `security-ops`. Integración gratuita de Socket.dev (CLI de código abierto, MCP `depscore` sin auth) más hooks de aviso tanto en comandos de instalación como en ediciones de manifiestos. `exposure-check.py` coteja lockfiles instalados (npm/pnpm/yarn/bun, PyPI, Composer, Cargo, Go, RubyGems + extensiones del editor) contra un catálogo de IOC citados; `integrity-audit.sh` busca persistencia de gusanos en configs, rc de shell y `.npmrc`; `preinstall-check.sh` impone un enfriamiento de edad de lanzamiento de 7 días. Un archivo global `rules/supply-chain.md` lleva la doctrina a todas partes; suite de pruebas offline de 42 aserciones, formato IOC de [Bumblebee](https://github.com/perplexityai/bumblebee) de Perplexity.

**v2.8.0** (Mayo 2026)
- 🩺 **Habilidad `mac-ops`** - Diagnósticos integrales de estación de trabajo macOS, par de `windows-ops`. 23 scripts + 11 documentos de referencia a lo largo de una escalera de 8 peldaños: `health-audit` orquesta y `quickrun` da un veredicto de un solo disparo sobre "¿qué le pasa a mi Mac?". Las sondas únicas de Mac cubren permisos de privacidad TCC (la causa de "no se puede compartir pantalla"), razones de reactivación, Spotlight y presión de almacenamiento APFS (el misterio de "disco lleno pero `du` no coincide").

**v2.6.0** (Mayo 2026)
- 🩺 **Habilidad `windows-ops`** - Diagnósticos integrales de estación de trabajo Windows. Siete scripts + cinco catálogos de referencia: `health-audit` renderiza un panel agrupado por estado y mapea `\Device\HarddiskN` → letra de unidad para que un veredicto nombre la unidad fallida real; `crash-triage` decodifica los códigos de BugCheck del Evento 41 y analiza los minutos antes de un fallo buscando pruebas evidentes; `recover-clone` envuelve `robocopy /R:0` para que los reintentos no aceleren la muerte de un disco agonizante.

**v2.5.0** (Mayo 2026)
- 🌐 **Habilidad `net-ops`** - Resolución de problemas de red multiplataforma (Windows / macOS / Linux) vía local o SSH remoto con una escalera diagnóstica por capas: enlace → ICMP → socket → infraestructura DNS → resolvedor OS → app. Clasificador IPv6 consciente de NDP (deshabilitado / solo-ULA / sin-ruta / ruta-rota / saludable), prueba MTU/PMTU, comprobación de desviación temporal, detección de DoH del navegador (Chrome / Brave / Firefox), conciencia de WSL2/contenedores. Modos: `--watch`, `--json` (NDJSON), `--redact` para volcados limpios de opsec, `--quick` para saltar si está saludable. Sonda por OS + dns-audit + scripts de reparación, sonda en modo inverso, suite de 24 pruebas.
- 🌐 **Habilidad `portless-ops`** - Operaciones de proxy HTTPS de desarrollo local para [portless](https://github.com/vercel-labs/portless) de Vercel Labs. Envuelve el `SKILL.md` y `oauth/SKILL.md` canónicos del upstream (vendidos textualmente en `references/` ya que el paquete npm solo envía `dist/`) y superpone patrones operativos que hemos validado: el patrón de alias estático para emparejar portless con supervisores externos (Process Compose, PM2, Docker), árbol de decisión de selección de TLD (`.test`/`.dev`/`.localhost`/propio), advertencias específicas de Windows (`openssl` PATH desde Git for Windows, peculiaridades de `certutil`, manejo de certs curl-vs-navegador, diferencias de flags PS 5.1 vs 7+), el procedimiento de reinicio limpio al cambiar TLDs (porque `portless alias --remove` añade el TLD activo), y tres scripts ejecutables: `install-portless.ps1` (audita el tarball de npm en busca de IOC de cadena de suministro conocidos *antes* de instalar), `reset-state.ps1` (borrado total de estado + registro), `sync-aliases-from-yaml.ps1` (deriva alias de portless desde el YAML de un supervisor). Cuatro plantillas de activos `portless.json` cubren patrones de app única, monorepo, TLD personalizado documentado y patrones inline en `package.json`.
- 🎛️ **Habilidad `process-compose-ops`** - Operaciones integrales para [Process Compose](https://github.com/F1bonacc1/process-compose), el supervisor binario en Go que reemplaza a PM2/supervisord/Foreman para servicios locales no contenedorizados. Seis archivos de referencia: `schema-reference.md` (esquema YAML completo con semántica de campos, valores predeterminados y errores de comillas de comandos, incluyendo el manejo de barras invertidas de Windows-PATH), `probe-patterns.md` (recetas de sondas de disponibilidad por stack — Python/Go/Node/solo-TCP/daemons), `dependency-patterns.md` (patrones de `depends_on`: daemons compañeros, DB-antes-que-app, túnel-después-de-servicio, init de un solo disparo), `tui-shortcuts.md` (guía rápida de teclas de TUI, leyenda de estado, búsqueda/ordenación), `boot-persistence-windows.md` (Programador de Tareas con inicio de sesión `S4U` y script wrapper consciente del PATH), `supply-chain-verification.md` (procedimiento de verificación SHA-256 para el binario). Cuatro scripts ejecutables: `install-process-compose.ps1` (descarga verificada + extracción + escribe `VERIFICATION.md`), `verify-binary.ps1` (re-verifica el hash del binario comprometido), más el wrapper de inicio y plantillas del instalador del Programador de Tareas. Cinco activos YAML: servicio Python, Django+compañeros, binario Go, patrón de túnel Cloudflare, trabajo cron. Material derivado de una migración de producción de 3 horas de PM2+Caddy+Dagu a Process Compose+portless, anonimizado para uso general.
- 📦 **Sincronización del manifiesto del plugin** - `summon` (v2.4.11) y `fleet-ops` (post-v2.4.11) fueron comprometidos y listados en el README pero nunca añadidos al array `components.skills` de `.claude-plugin/plugin.json`, por lo que no estaban siendo indexados por el sistema de plugins. Ambos registrados correctamente ahora junto al nuevo par.
- 🗑️ **Eliminación del comando `/canvas` y del paquete `canvas-tui`** - El comando canvas era experimental, específico de Warp-terminal y no se usaba. La eliminación elimina la única superficie de dep-runtime de npm en claude-mods (lockfile de 2,096 líneas + 17 archivos fuente de TypeScript/React + README empaquetado de 117 líneas), dejando el repo solo con markdown + bash. Incremento menor en lugar de parche porque elimina una API pública documentada (`/canvas`). Co-desarrollado en la rama `claude/sad-almeida-20699c` por una sesión hermana de Opus 4.7 e integrado en este lanzamiento.

**v2.4.11** (Mayo 2026)
- ✨ **Habilidad `summon`** - Empuja sesiones de la pestaña de Código de Claude Desktop entre cuentas para que aparezcan en la siguiente cuenta a la que cambies. Se recomienda ejecutarlo *antes* de cambiar — mientras estés en tu cuenta actual casi al límite, empuja las sesiones en curso al destino, luego Cierra Sesión/Inicia Sesión como cambio natural. El valor predeterminado es copiar (sesiones visibles desde ambas cuentas); `--move` para una limpieza ligera. Selector jerárquico Cuenta → Proyecto → Sesión con numeración global, `--peek <id>` para vista previa de transcripción, inventario `--list-accounts`, alias de recencia (`--1d/--3d/--7d/--all`), sistema de consejos rotativos de 8 pistas. La salida sigue `docs/TERMINAL-DESIGN.md` (Sistema de Diseño de Panel de Terminal).

[Ver changelog completo →](CHANGELOG.md)

## ¿Por qué claude-mods?

Claude Code es potente de fábrica, pero tiene vacíos. Este kit los llena:

- **Continuidad de sesión** — Las tareas desaparecen cuando terminan las sesiones. Lo solucionamos con `/save` y `/sync`, implementando el [patrón recomendado](https://www.anthropic.com/engineering/effective-harnesses-for-long-running-agents) de Anthropic para agentes de larga ejecución.

- **Conocimiento de nivel experto bajo demanda** — 102 habilidades bajo demanda que cubren React, TypeScript, Python, Go, Rust, PostgreSQL y más, además de 3 agentes especializados reservados para roles genuinos de aislamiento de contexto/trabajador (operaciones de git, raspado web, reorganización de proyectos). Prioridad a las habilidades: el conocimiento se carga cuando es relevante en lugar de vivir en prompts de agentes pesados.

- **Herramientas de CLI modernas** — Deja de usar `grep`, `find` y `cat`. Nuestras reglas prefieren automáticamente `ripgrep`, `fd`, `eza` y `bat` — de 10 a 100 veces más rápidos y eficientes en tokens.

- **Recuperación web inteligente** — Una jerarquía de respaldo que realmente funciona: WebFetch → Jina Reader → Firecrawl. No más "no puedo acceder a esa URL".

- **Patrones de flujo de trabajo** — Ciclos de TDD, revisión de código, desarrollo de funcionalidades, depuración — todo documentado con las mejores prácticas de Anthropic.

## Beneficios Clave

- **Estado de tarea persistente** — Retoma exactamente donde lo dejaste, incluso entre máquinas.
- **Experiencia de dominio** — Agentes entrenados en documentación de frameworks, no solo conocimiento general.
- **Eficiencia de tokens** — Las herramientas de CLI modernas producen una salida más limpia, ahorrando ventana de contexto.
- **Compartición en equipo** — Los archivos de estado rastreables por git funcionan en todo tu equipo.
- **Listo para producción** — Suite de pruebas validada, formato de plugin adecuado, documentación exhaustiva.
- **Pensamiento extendido** — Guía integrada para disparadores de "pensar profundamente" y "ultrapensar".
- **Cero bloqueo (lock-in)** — Formato estándar de plugin de Claude Code, actívalo/desactívalo en cualquier momento.

## Estructura

```
claude-mods/
├── .claude-plugin/     # Metadatos del plugin
├── agents/             # Subagentes expertos (3)
├── commands/           # Comandos slash (3)
├── skills/             # Habilidades personalizadas (102)
├── output-styles/      # Personalidades de respuesta
├── hooks/              # Ejemplos y docs de hooks
├── rules/              # Reglas de Claude Code
├── tools/              # Instaladores del kit de herramientas CLI modernas
├── scripts/            # Scripts de instalación del plugin
├── tests/              # Suites de pruebas + justfile
├── docs/               # Documentación del proyecto
└── templates/          # Plantillas de extensión
```

## Instalación

### Instalación del Plugin (Recomendado)

```bash
# Paso 1: Agregar el marketplace
/plugin marketplace add 0xDarkMatter/claude-mods

# Paso 2: Instalar el plugin
/plugin install claude-mods@0xDarkMatter-claude-mods
```

Esto se instala globalmente (disponible en todos los proyectos). Actívalo/desactívalo con el menú `/plugin`.

### Instalación por Script

```bash
git clone https://github.com/0xDarkMatter/claude-mods.git
cd claude-mods
bash scripts/install.sh
```

Funciona en Linux, macOS y Windows (Git Bash). También hay una alternativa de PowerShell en `scripts/install.ps1`.

Los scripts de instalación:
- Copian comandos, habilidades, agentes, reglas y estilos de salida a `~/.claude/`
- Limpian elementos obsoletos (ej. el antiguo comando `/conclave`)
- Eliminan habilidades renombradas (ej. `-patterns` -> `-ops`)
- Gestionan migraciones de comando→habilidad (no crean duplicados)
- Preservan cualquier habilidad extra instalada por separado (ej. habilidades específicas del proyecto)

### Herramientas de CLI (Opcional)

Instala herramientas de CLI modernas (fd, rg, bat, etc.) para un mejor rendimiento:

```bash
# Windows (PowerShell Admin)
.\tools\install-windows.ps1

# Linux/macOS
./tools/install-unix.sh
```

## Arquitectura de Habilidades

Todas las habilidades cumplen con la [especificación de Agent Skills](https://agentskills.io/specification) y siguen una estructura consistente:

```
nombre-de-la-habilidad/
├── SKILL.md              # Flujo de trabajo central (< 500 líneas)
├── scripts/              # Código ejecutable (opcional)
├── references/           # Documentación cargada según necesidad (opcional)
└── assets/               # Plantillas/archivos de salida (opcional)
```

**Carga Progresiva:**
1. Metadatos (nombre + descripción) - Siempre en contexto (~100 palabras)
2. Cuerpo de SKILL.md - Cargado cuando la habilidad se dispara (<5k palabras)
3. Recursos empaquetados - Cargados solo cuando Claude los necesita

Todas las habilidades tienen la estructura de directorio completa, incluso si `scripts/`, `references/` o `assets/` están vacíos actualmente. Esto garantiza la consistencia y facilita la adición de recursos empaquetados más adelante.

Consulta [skill-creator](skills/skill-creator/) para la guía completa.

## Qué Incluye

### Comandos

| Comando | Descripción |
|---------|-------------|
| [sync](commands/sync.md) | Bootstrap de sesión - restaura tareas, plan, contexto de git/PR. Sugiere `--resume` y `--from-pr`. |
| [save](commands/save.md) | Persiste tareas, plan, contexto de git/PR y resumen de sesión en la memoria nativa. |

### Habilidades

#### Habilidades de Lenguaje y Framework
| Habilidad | Descripción |
|-------|-------------|
| [go-ops](skills/go-ops/) | Concurrencia en Go, manejo de errores, pruebas, interfaces, genéricos, estructura de proyecto |
| [rust-ops](skills/rust-ops/) | Propiedad de Rust, async/tokio, manejo de errores, traits, serde, ecosistema |
| [typescript-ops](skills/typescript-ops/) | Sistema de tipos de TypeScript, genéricos, tipos de utilidad, modo estricto, Zod |
| [javascript-ops](skills/javascript-ops/) | Patrones asíncronos de JavaScript/Node.js, módulos, ES2024+, internos del runtime |
| [r-ops](skills/r-ops/) | R moderno - análisis de datos basado en tidyverse, manipulación con dplyr/tidyr, ggplot2, stats/modelado (broom, tidymodels), data.table, series temporales, flujo renv/Quarto |
| [react-ops](skills/react-ops/) | Hooks de React, Server Components, gestión de estado, rendimiento, pruebas |
| [vue-ops](skills/vue-ops/) | Vue 3 Composition API, Pinia, Vue Router, Nuxt 3 |
| [astro-ops](skills/astro-ops/) | Islas de Astro, colecciones de contenido, estrategias de renderizado, despliegue |
| [laravel-ops](skills/laravel-ops/) | Laravel Eloquent, arquitectura, autenticación, pruebas con Pest |
| [craftcms-ops](skills/craftcms-ops/) | Craft CMS 5 - entradas/secciones/campos, Matrix-as-entries, Twig, consultas de elementos, GraphQL, plugins |
| [payloadcms-ops](skills/payloadcms-ops/) | Payload CMS 3 (nativo de Next.js) - colecciones/globales, API Local, control de acceso, hooks, campos |
| [cli-ops](skills/cli-ops/) | Patrones de herramientas CLI para producción - flujos agénticos, separación de flujos, códigos de salida |
| [bash-ops](skills/bash-ops/) | Bash defensivo - modo estricto, traps, parsing seguro de argumentos, códigos de salida semánticos, shellcheck, scripts de CI |
| [cypress-ops](skills/cypress-ops/) | Pruebas e2e + de componentes con Cypress - selectores data-test, cy.intercept, cy.session, Test Replay, diagnóstico de flakes |
| [tailwind-ops](skills/tailwind-ops/) | Patrones de Tailwind CSS, migración v4, componentes, configuración |
| [color-ops](skills/color-ops/) | Espacios de color, comprobador de contraste WCAG/APCA, generadores de paleta + armonía, funciones de color CSS, tokens de diseño, convertidor de color |
| [genart-ops](skills/genart-ops/) | Arte generativo - escenas de three.js, bocetos de p5.js, generación de SVG, shaders GLSL, algoritmos procedimentales, teoría del color |
| [threejs-ops](skills/threejs-ops/) | three.js a escala de app/juego - realidad de import maps + ES-modules, pipeline GLTF (DRACO/KTX2/meshopt, gltf-transform), crossfades de AnimationMixer, bucles de timestep fijo, física rapier/cannon-es, R3F + drei, disciplina de InstancedMesh/LOD/disposal, actores de boids/steering; verificador de obsolescencia de npm |
| [mapbox-ops](skills/mapbox-ops/) | Mapbox GL JS avanzado (web v3) - marcadores personalizados, dataviz temática, 3D/terreno, cámara cinematográfica, composición de estilos, expresiones, rendimiento, errores comunes; verificador de mapas headless Playwright |
| [isometric-ops](skills/isometric-ops/) | Creación de activos isométricos de extremo a extremo - matemática exacta de proyección (iso real vs dimétrica 2:1), generación de SVG/CSS/three.js, pipelines de pixel-art + pre-render de Blender, tilemaps de motores, generación de IA con control de estructura de ControlNet, scripts de QA de tiles + empaquetado de atlas; dirige al compositor de escenas compañero [iso-studio](https://github.com/0xDarkMatter/iso-studio) (ajuste a rejilla, y-sort, exportación de bloqueo a ControlNet) |
| [svg-brand-tint-ops](skills/svg-brand-tint-ops/) | Estudio de SVG en el navegador sin dependencias - recoloración de marca tri-tono impulsada por tokens (feColorMatrix/feComponentTransfer + horneado de CSS-filter consciente del tema) y un vectorizador raster desde cero (PNG->SVG) con una etapa de geometría Potrace-paper (rectitud/polígono-óptimo/ajuste-vértice/alphamax, sin código GPL) sobre marching squares de campo suave con manejo de paleta consciente de alfa; Google Fonts curadas, stack de filtros, servidor sin dependencias + CLI de trazo headless que comparten un mismo motor |
| [unfold-admin](skills/unfold-admin/) | Tema de administración Django Unfold - ModelAdmin, tableros, filtros, widgets, temáticos |

#### Habilidades de Python
| Habilidad | Descripción |
|-------|-------------|
| [python-async-ops](skills/python-async-ops/) | Concurrencia asyncio, aiohttp, manejo de errores, mezcla sincrónica/asincrónica, patrones de producción |
| [python-cli-ops](skills/python-cli-ops/) | CLIs con Click/Typer/argparse, manejo de flujos, empaquetado |
| [python-database-ops](skills/python-database-ops/) | SQLAlchemy async, pooling de conexiones, transacciones |
| [python-fastapi-ops](skills/python-fastapi-ops/) | Inyección de dependencias de FastAPI, tareas en segundo plano, Pydantic |
| [python-observability-ops](skills/python-observability-ops/) | Logging estructurado, trazas, métricas para servicios Python |
| [python-pytest-ops](skills/python-pytest-ops/) | Fixtures de pytest, parametrización, pruebas basadas en propiedades |
| [python-typing-ops](skills/python-typing-ops/) | Genéricos avanzados, estrechamiento de tipos (type narrowing), validación en tiempo de ejecución |

#### Habilidades de Datos y API
| Habilidad | Descripción |
|-------|-------------|
| [api-design-ops](skills/api-design-ops/) | Patrones de diseño REST, gRPC, GraphQL, versionado, auth, limitación de tasa |
| [rest-ops](skills/rest-ops/) | Métodos HTTP, códigos de estado, referencia rápida de REST |
| [sql-ops](skills/sql-ops/) | CTEs, funciones de ventana, patrones de JOIN, indexación |
| [postgres-ops](skills/postgres-ops/) | Operaciones de PostgreSQL, optimización, diseño de esquema, replicación, monitoreo |
| [sqlite-ops](skills/sqlite-ops/) | Esquemas de SQLite, patrones de python sqlite3/aiosqlite |
| [claude-api-ops](skills/claude-api-ops/) | Construir sobre Claude - API de Messages, uso de herramientas, caché de prompts, salidas estructuradas, batches, SDK de Agente |
| [mcp-ops](skills/mcp-ops/) | Desarrollo de servidores MCP, FastMCP, transportes, diseño de herramientas, pruebas |

#### Habilidades de Infraestructura
| Habilidad | Descripción |
|-------|-------------|
| [docker-ops](skills/docker-ops/) | Mejores prácticas de Dockerfile, compilaciones multi-etapa, Compose, optimización |
| [ci-cd-ops](skills/ci-cd-ops/) | GitHub Actions, automatización de lanzamientos, pipelines de prueba |
| [container-orchestration](skills/container-orchestration/) | Kubernetes, Helm, patrones de pods |
| [nginx-ops](skills/nginx-ops/) | Proxy inverso Nginx, SSL/TLS, balanceo de carga, ajuste de rendimiento |
| [cloudflare-ops](skills/cloudflare-ops/) | Cloudflare Workers/Pages - wrangler (despliegue, config jsonc), bindings (KV/D1/R2/DO/Queues/AI), despliegue edge + CI |
| [auth-ops](skills/auth-ops/) | JWT, OAuth2, sesiones, RBAC/ABAC, passkeys, MFA |
| [monitoring-ops](skills/monitoring-ops/) | Prometheus, Grafana, OpenTelemetry, logging estructurado, alertas |
| [debug-ops](skills/debug-ops/) | Depuración sistemática, depuradores específicos de lenguaje, escenarios comunes |
| [perf-ops](skills/perf-ops/) | Perfilado de rendimiento - CPU, memoria, análisis de bundle, pruebas de carga, flamegraphs |
| [terraform-ops](skills/terraform-ops/) | IaC con Terraform/OpenTofu - gestión de estado, patrones de módulos, CI/CD OIDC, detección de deriva, secretos |
| [supply-chain-defense](skills/supply-chain-defense/) | Seguridad de dependencias basada en comportamiento - Socket.dev (CLI gratuita + MCP depscore), exposure-check (coincidencia de IOC en npm/pnpm/yarn/bun/PyPI/Composer/Cargo/Go/RubyGems + extensiones), integrity-audit (persistencia de gusanos), escaneo de extensiones, hooks de instalación/manifiesto |
| [prompt-injection-defense](skills/prompt-injection-defense/) | Defensa de integridad de instrucciones - escaneo de Unicode oculto (bidi/Trojan Source, contrabando de bloques de etiquetas, ancho cero), saneamiento de contenido, doctrina de límite de confianza |
| [security-ops](skills/security-ops/) | Auditoría de seguridad reactiva - 3 agentes paralelos (CVE de dependencias, patrones SAST, revisión de auth/config) consolidados en un informe mapeado a OWASP |
| [portless-ops](skills/portless-ops/) | Operaciones de proxy HTTPS de desarrollo local para portless de Vercel Labs - selección de TLD, emparejamiento de supervisores, advertencias de Windows |
| [process-compose-ops](skills/process-compose-ops/) | Operaciones del supervisor Process Compose - esquema YAML, sondas de disponibilidad, patrones de dependencias, persistencia de inicio |
| [pypi-ops](skills/pypi-ops/) | Publicación en PyPI - Publicación Confiable OIDC + atestaciones PEP 740, corrección de primer envío de publicador pendiente (`invalid-publisher`), scripts de pre-vuelo/diagnóstico/verificador-de-pin, `publish.yml` endurecido, rutas locales de uv y twine |

#### Diagnósticos de Estación de Trabajo y Red
| Habilidad | Descripción |
|-------|-------------|
| [windows-ops](skills/windows-ops/) | Diagnósticos de estación de trabajo Windows - auditoría de salud, triaje de fallos, mapeo de unidades, recuperación de discos agonizantes |
| [mac-ops](skills/mac-ops/) | Diagnósticos de estación de trabajo macOS - permisos de privacidad TCC, razones de reactivación, Spotlight, presión de almacenamiento APFS |
| [net-ops](skills/net-ops/) | Resolución de problemas de red multiplataforma - escalera en capas desde enlace hasta app, clasificador IPv6, detección de DoH, MTU/PMTU |
| [asus-router-ops](skills/asus-router-ops/) | Routers Asus / Asuswrt-Merlin - endurecimiento, WireGuard/OpenVPN, segmentación, privacidad DNS, scripting JFFS |

#### Habilidades de Herramientas CLI
| Habilidad | Descripción |
|-------|-------------|
| [file-search](skills/file-search/) | Buscar archivos con fd, buscar código con rg, seleccionar con fzf |
| [find-replace](skills/find-replace/) | Búsqueda y reemplazo moderno con sd |
| [code-stats](skills/code-stats/) | Analizar base de código con tokei y difft |
| [data-processing](skills/data-processing/) | Procesar JSON con jq, YAML/TOML con yq |
| [markitdown](skills/markitdown/) | Convertir PDF, Word, Excel, PowerPoint, imágenes a markdown |
| [ffmpeg-ops](skills/ffmpeg-ops/) | Operaciones de ffmpeg/ffprobe - libro de cocina basado en sondeo (transcodificación, corte/concatenación, GIF, subtítulos, HLS), triaje `--doctor` con comandos de corrección, edición impulsada por EDL, preparación para STT/Whisper, puertas de calidad VMAF, autoría de capítulos, compresión de tamaño objetivo, sprites de vista previa de scrubbing, verificación de codificadores de hardware, y un ala completa de gradación: catálogo de recetas de ~40 looks, 32 LUTs paramétricas (mapas de tono mono/duo/tritone), extracción de Hald-CLUT, doctrina de coincidencia de scopes. 11 scripts de protocolo, 19 referencias, suite de 107 aserciones |
| [ytdlp-ops](skills/ytdlp-ops/) | Capa de adquisición yt-dlp que alimenta a ffmpeg-ops - selección de formato que evita transcodificaciones (orden `-S`), secciones de recorte en la descarga, extracción de audio STT, sincronizaciones de canal impulsadas por archivo, cookies/auth, SponsorBlock, triaje de fallos (nsig = obsoleto). Verificador de obsolescencia conectado a la CI + vigencia |
| [structural-search](skills/structural-search/) | Buscar código por estructura de AST con ast-grep |
| [log-ops](skills/log-ops/) | Análisis de logs, procesamiento de JSONL, correlación de logs cruzados, reconstrucción de línea de tiempo |
| [leveldb-ops](skills/leveldb-ops/) | Leer almacenes LevelDB de Chromium/Electron (Local Storage, IndexedDB) - forense de estado de app |

#### Habilidades de Flujo de Trabajo
| Habilidad | Descripción |
|-------|-------------|
| [tool-discovery](skills/tool-discovery/) | Recomendar agentes y habilidades para cualquier tarea |
| [git-ops](skills/git-ops/) | Orquestador de Git - commits, PRs, lanzamientos, changelog. Dirige a un agente Sonnet en segundo plano. |
| [github-ops](skills/github-ops/) | Operaciones remotas de GitHub - creación de repo/metadatos/tópicos, lanzamientos + cumplimiento de 'Actualizaciones Recientes' en README, gestión de issues/PR (vista previa antes de enviar), y auditoría de postura de seguridad de solo lectura + repo-scorecard puntuada (un solo repo o `--org` completa) |
| [push-gate](skills/push-gate/) | Puerta de seguridad pre-push - escaneo de secretos gitleaks + regex, comprobación de archivos prohibidos, sin bypass |
| [parallel-ops](skills/parallel-ops/) | Router para trabajo de agentes paralelo/recurrente - tabla de decisión sobre fleet-ops, fleet-worker, fleetflow, loop-ops, iterate, spawn |
| [fleet-ops](skills/fleet-ops/) | Gestionar una flota de sesiones de Claude concurrentes - cola de aterrizaje con puerta de pruebas, limpieza pre-aterrizaje (experimental) |
| [fleet-worker](skills/fleet-worker/) | Delegar tareas a trabajadores GLM headless económicos (o cualquier worker compatible con Anthropic) - git worktree por tarea + config aislada, filtrado de resultados, distribución que entrega ramas ganadoras al aterrizaje de fleet-ops |
| [fleetflow](skills/fleetflow/) | Orquestar una flota de trabajadores heterogéneos - trabajadores de proceso GLM (z.ai), Codex (OpenAI) y Anthropic Sonnet/Opus/Haiku bajo un orquestador Fable/Opus, portando los patrones de la herramienta Workflow nativa (reanudación de diario con clave hash, pipeline-vs-barrera, verificación adversarial, paneles de jueces) con un guardia de escape integrado; scripts ff-spawn / ff-collect / ff-doctor |
| [summon](skills/summon/) | Caja de herramientas de sesión de Claude Desktop - transferencia entre cuentas, selector de recuperación, re-vinculación de cwd, doctor de almacenamiento |
| [doc-scanner](skills/doc-scanner/) | Escanear y sintetizar la documentación del proyecto |
| [repo-doctor](skills/repo-doctor/) | Auditar cualquier repo frente a la doctrina de calidad agéntica - docs de entrada, contratos de comentarios, estructura, puertas de cumplimiento, emparejamiento de docs; calificador con --json + CI --strict, más referencias de doctrina-de-comentarios / docs-de-entrada / estructura-de-monorepo |
| [adr-ops](skills/adr-ops/) | Architecture Decision Records - cuándo escribir, formato canónico, ciclo de vida de superación, herramientas de andamiaje/índice/lint |
| [okf-ops](skills/okf-ops/) | Open Knowledge Format - evaluar la preparación de frontmatter de un repo de docs, validar la conformidad de un paquete, decidir adopción por repo |
| [project-planner](skills/project-planner/) | Rastrear planes obsoletos, sugerir comandos de sesión |
| [python-env](skills/python-env/) | Gestión rápida de entornos Python con uv |
| [task-runner](skills/task-runner/) | Ejecutar comandos del proyecto con just |
| [screenshot](skills/screenshot/) | Buscar y mostrar capturas de pantalla recientes de directorios comunes de capturas |
| [pigeon](skills/pigeon/) | pmail entre sesiones - enviar/recibir mensajes entre sesiones de Claude Code a través de proyectos. Respaldado por SQLite (`~/.claude/pmail.db`), identidad de proyecto basada en git, hilos, adjuntos, difusión, búsqueda. Notificaciones impulsadas por hooks. Desactivación por proyecto. |

#### Habilidades de Desarrollo
| Habilidad | Descripción |
|-------|-------------|
| [auto-skill](skills/auto-skill/) | Detectar automáticamente flujos de trabajo dignos de una habilidad y crear habilidades reutilizables. El hook sugiere después de sesiones complejas (8+ ops mutantes en 4+ tipos de herramientas). Cumple la especificación de Agent Skills con puertas de calidad y detección de duplicados. Alternar con `/auto-skill on/off`. |
| [skill-creator](skills/skill-creator/) | Guía para crear habilidades efectivas con conocimiento especializado, flujos de trabajo e integraciones de herramientas. |
| [explain](skills/explain/) | Explicación profunda de código complejo, archivos o conceptos. Dirige a agentes expertos. |
| [spawn](skills/spawn/) | Generar prompts de agentes expertos de nivel PhD para Claude Code. |
| [atomise](skills/atomise/) | Razonamiento de Átomo de Pensamientos (Atom of Thoughts) - descomponer problemas en unidades atómicas. |
| [setperms](skills/setperms/) | Establecer permisos de herramientas y preferencias de CLI en el directorio .claude/. |
| [introspect](skills/introspect/) | Analizar logs de sesiones anteriores sin consumir el contexto actual. |
| [review](skills/review/) | Revisión de código con diffs semánticos, enrutamiento experto y auto-TaskCreate. |
| [testgen](skills/testgen/) | Generar pruebas con enrutamiento experto y detección de framework. |
| [techdebt](skills/techdebt/) | Detección de deuda técnica mediante subagentes paralelos. |
| [migrate-ops](skills/migrate-ops/) | Patrones de migración de framework/lenguaje, actualizaciones de versión, codemods |
| [refactor-ops](skills/refactor-ops/) | Patrones de refactorización segura, detección de código maloliente (code smell), metodología impulsada por pruebas |
| [scaffold](skills/scaffold/) | Andamiaje de proyecto - generar boilerplate para APIs, apps web, CLIs, monorepos |
| [iterate](skills/iterate/) | Bucle de mejora autónoma - modificar, medir, mantener o descartar, repetir. Inspirado en autoresearch de Karpathy. |
| [loop-ops](skills/loop-ops/) | Disciplina de diseño de bucle externo - la capa de orquestación sobre `iterate`: escalera de niveles de riesgo (L1 reporte → L2 asistido → L3 desatendido) mapeada al modelo de permisos de Claude Code, columna de ESTADO/log-de-ejecución/presupuesto, una morfología de 13 patrones (cadencia/evento/meta × L1–L3 × nube/local), coordinación de bucles múltiples, interruptor de apagado. Compone iterate/fleet-worker/fleet-ops/native-loop. Scripts loop-scaffold/loop-check/loop-estimate. |
| [testing-ops](skills/testing-ops/) | Patrones de estrategia de pruebas - mocking, pruebas en CI, diseño de datos de prueba |
| [claude-code-ops](skills/claude-code-ops/) | Internos de Claude Code - catálogo completo de eventos de hook, especificación de frontmatter de habilidad, referencia headless/CLI, depuración de extensiones |
| [playwright-ops](skills/playwright-ops/) | Pruebas e2e de Playwright - jerarquía de selectores, fixtures, mocking de red, sharding en CI, caza de flakes |

### Hooks

| Hook | Tipo | Descripción |
|------|------|-------------|
| [pre-commit-lint.sh](hooks/pre-commit-lint.sh) | PreToolUse | Auto-lint de archivos preparados antes del commit (JS/TS, Python, Go, Rust, PHP) |
| [post-edit-format.sh](hooks/post-edit-format.sh) | PostToolUse | Auto-formateo de archivos después de Write/Edit (Prettier, Ruff, gofmt, rustfmt) |
| [dangerous-cmd-warn.sh](hooks/dangerous-cmd-warn.sh) | PreToolUse | Bloquea comandos destructivos (force push, rm -rf, DROP TABLE) |
| [enforce-uv.sh](hooks/enforce-uv.sh) | PreToolUse | Impone uv sobre pip/herramientas básicas en proyectos uv (`pip install` → `uv add`, `pytest`/`ruff` solos → `uv run`) |
| [pre-install-scan.sh](hooks/pre-install-scan.sh) | PreToolUse | Aviso sobre instalaciones de dependencias (npm/pnpm/yarn/bun/pip/uv/poetry/composer/gem/cargo, incl. `composer update`) - pasa por Socket, respeta enfriamiento; `SUPPLY_CHAIN_BLOCK=1` para un bloqueo estricto |
| [manifest-dep-scan.sh](hooks/manifest-dep-scan.sh) | PostToolUse | Aviso cuando el agente edita un manifiesto de dependencias (package.json/requirements/composer.json/Cargo.toml/go.mod/Gemfile) - depscore + enfriamiento del paquete añadido; silencioso en subidas de versión |
| [check-mail.sh](hooks/check-mail.sh) | PreToolUse | Busca pmail no leído mediante archivo de señal (sin enfriamiento, costo cero si está vacío) |
| [session-start-unicode-scan.sh](hooks/session-start-unicode-scan.sh) | SessionStart | Escaneo de una sola pasada de Unicode oculto en archivos de instrucciones del proyecto al iniciar (silencioso si está limpio) |
| [pre-commit-unicode-scan.sh](hooks/pre-commit-unicode-scan.sh) | Git pre-commit | Bloquea commits que añadan Unicode oculto crítico (bidi, bloque de etiquetas) a archivos de instrucciones |
| [config-change-guard.sh](hooks/config-change-guard.sh) | ConfigChange | Escanea archivos de configuración de Claude cambiados en busca de IOC de persistencia de gusanos en el momento en que se editan (aviso; `SUPPLY_CHAIN_BLOCK=1` para denegar) |
| [worktree-guard.sh](hooks/worktree-guard.sh) | PreToolUse | Advierte sobre comandos que toquen `.claude/worktrees/` de otras sesiones (rm, worktree remove/prune, `git add -A` sweeping, doble-force `git clean -ff`); `WORKTREE_GUARD_BLOCK=1` para denegar |
| [pre-write-peer-guard.sh](hooks/pre-write-peer-guard.sh) | PreToolUse | Guardia de escritura entre pares en sesión — advierte antes de escribir un archivo que una sesión activa en el mismo checkout acaba de modificar (las colisiones ocurren durante una sesión, no solo al inicio); se empareja con session-touched-ledger.sh |
| [session-touched-ledger.sh](hooks/session-touched-ledger.sh) | PostToolUse | Registra los archivos que esta sesión ha escrito para que la guardia de escritura entre pares pueda distinguir ediciones propias de las de un compañero (silencioso, nunca bloquea) |

### Estilos de Salida

| Estilo | Personalidad | Ideal Para |
|-------|-------------|----------|
| [Vesper](output-styles/vesper.md) | Ingenio británico sofisticado, profundidad intelectual | Trabajo de desarrollo general |
| [Spartan](output-styles/spartan.md) | Minimalista, solo puntos clave | Tareas rápidas, salida de CI |
| [Mentor](output-styles/mentor.md) | Paciente, educativo | Aprendizaje, onboarding |
| [Executive](output-styles/executive.md) | Resúmenes de alto nivel | Partes interesadas no técnicas |
| [Pair](output-styles/pair.md) | Piensa en voz alta, explora junto al usuario | Resolución colaborativa de problemas |
| [Atlas](output-styles/atlas.md) | Asesor estratégico, pensamiento sistémico | Arquitectura, planificación |
| [Coach](output-styles/coach.md) | Celebra victorias, impulsa a subir de nivel | Impulso, motivación |
| [Harbour](output-styles/harbour.md) | Cálido, estable, tranquilo en la tormenta | Tareas complejas o estresantes |
| [Meridian](output-styles/meridian.md) | Jefe de gabinete, anticipatorio | Coordinación de proyectos |
| [Noir](output-styles/noir.md) | Detective duro, Chandler conoce a SRE | Depuración, investigaciones |
| [Roast](output-styles/roast.md) | Amigo brutalmente honesto | Revisión de código, mejora |
| [Sage](output-styles/sage.md) | Reflexivo, medido, preciso | Post-mortems, análisis |
| [Scout](output-styles/scout.md) | Curioso, lateral, desafía suposiciones | Diseño, reformulación de problemas |

### Agentes

> **Prioridad a las Habilidades (v3.0):** los agentes expertos en lenguaje/framework (python-expert, react-expert, etc.) fueron
> obsoletos en favor de sus gemelos de habilidades `-ops` — el contenido único del agente se integró en las habilidades.
>
> **Por qué, según la guía de Anthropic:** las habilidades y los subagentes resuelven problemas diferentes. El valor de un subagente es
> el *aislamiento del contexto* — se ejecuta en una ventana de contexto separada para que una investigación grande y ruidosa devuelva solo su
> resultado destilado al hilo principal. Las habilidades son el hogar del *conocimiento*: gracias a la revelación progresiva
> cuestan ~100 tokens (nombre + descripción) hasta que son relevantes, luego cargan su cuerpo y referencias bajo demanda. Un agente `python-expert` que solo contenía conocimiento de Python no aprovechaba el beneficio del aislamiento — era un contenedor de conocimiento que pagaba un costo de despacho y duplicaba las habilidades `python-*-ops` (5 de los 11 agentes retirados *no* tenían contenido que su gemelo de habilidad no tuviera). El conocimiento pertenece a las habilidades; los subagentes se reservan para la delegación que necesita su propio contexto o modelo.
>
> La delegación permanece donde se justifica: las habilidades de despacho (review, testgen, perf-ops, security-ops,
> explain) siguen dirigiéndose a agentes de `propósito-general` — pero esos agentes ahora *precargan la habilidad relevante* para su conocimiento. Subagente = el mecanismo de aislamiento, habilidad = el conocimiento que carga. Los agentes a continuación permanecen porque no tienen un gemelo de habilidad (una capacidad distinta, o — como git-agent — un rol real de trabajador en segundo plano que utiliza el límite de aislamiento).
>
> El estado final es limpio: **cada agente de conocimiento de dominio es ahora una habilidad**, y los únicos agentes que quedan son los tres cuyo valor *es* el mecanismo de aislamiento — git-agent (un trabajador en segundo plano), firecrawl-expert (raspidos grandes y ruidosos) y project-organizer (reestructuración masiva del sistema de archivos).
>
> Fuentes: [Agent Skills](https://code.claude.com/docs/en/skills) — revelación progresiva y carga bajo demanda; [Subagents](https://code.claude.com/docs/en/sub-agents) — una ventana de contexto separada para trabajo delegado.

| Agente | Descripción |
|-------|-------------|
| [firecrawl-expert](agents/firecrawl-expert.md) | Raspado web, rastreo, obtención paralela, extracción estructurada |
| [git-agent](agents/git-agent.md) | Operaciones de git en segundo plano - commits, PRs, lanzamientos (Sonnet) |
| [project-organizer](agents/project-organizer.md) | Reorganizar estructuras de directorios, limpieza |

### Reglas

| Regla | Descripción |
|------|-------------|
| [cli-tools.md](rules/cli-tools.md) | Preferencias de herramientas CLI modernas (fd, rg, eza, bat, etc.) |
| [commit-style.md](rules/commit-style.md) | Formato de commits convencionales y ejemplos |
| [naming-conventions.md](rules/naming-conventions.md) | Patrones de nomenclatura de componentes para agentes, habilidades, comandos |
| [prompt-injection.md](rules/prompt-injection.md) | Defensa de integridad de instrucciones - escaneo al entrar, saneamiento al ingestar, higiene de Unicode oculto |
| [skill-agent-updates.md](rules/skill-agent-updates.md) | Comprobación obligatoria de docs antes de crear/actualizar habilidades o agentes |
| [supply-chain.md](rules/supply-chain.md) | Higiene de dependencias basada en comportamiento - escanear antes de añadir, enfriamiento día-cero, auditoría OIDC, conciencia de hooks de persistencia |
| [worktree-boundaries.md](rules/worktree-boundaries.md) | Nunca tocar los worktrees de otras sesiones - nada de rm -rf, nada de git add -A sweeping gitlinks |
| [loop-engineering.md](rules/loop-engineering.md) | Disciplina de autonomía gradual para bucles de agentes programados/autónomos - L1→L2→L3, programador-no-sesión, puerta de escalada, interruptor de apagado + presupuesto; compañero de loop-ops |
| [agentic-quality.md](rules/agentic-quality.md) | Código, comentarios y estructura que sobreviven a la sesión - prueba de agente frío, doctrina de comentarios (bloques de contrato, solo el PORQUÉ, comentarios de guardia), estándar de doc-de-entrada, disciplina de tamaño de archivo, indexación + emparejamiento de docs; compañero de repo-doctor |
| [dev-servers.md](rules/dev-servers.md) | Nunca iniciar servidores de desarrollo locales ad-hoc - regístralos bajo un stack de process-compose + portless con un registro de puertos; regla de plantilla (adaptar rutas), compañero de process-compose-ops/portless-ops |
| [modern-tools.md](rules/modern-tools.md) | Imposición de qué herramienta usar al generar comandos - moderno por defecto (uv, fd, rg, sd), nota al pie para legado; compañero de cli-tools.md |
| [public-posts.md](rules/public-posts.md) | Vista previa antes de enviar para superficies públicas - citar el borrador verbatim y esperar aprobación explícita antes de comentarios de gh, PRs o cualquier publicación externa |
| [release-review.md](rules/release-review.md) | Nunca publicar lanzamientos de GitHub automáticamente - enviar commit+tag, detenerse, mostrar el diff para revisión humana antes de gh release create |
| [shell-preference.md](rules/shell-preference.md) | Hablar el shell del usuario, nunca asumir bash - señales de detección de shell más un ejemplo trabajado de PowerShell 5.1 con la tabla de traducción de bash-a-PowerShell |

### Herramientas y Hooks

| Recurso | Descripción |
|----------|-------------|
| [tools/](tools/) | Kit de herramientas CLI modernas - reemplazos eficientes en tokens para comandos legados |
| [hooks/](hooks/) | Ejemplos de hooks para automatización de pre/post ejecución |

#### Jerarquía de Obtención Web

Al obtener contenido web, las herramientas se usan en este orden:

| Prioridad | Herramienta | Cuándo usar |
|----------|------|-------------|
| 1 | `WebFetch` | Primer intento - rápido, integrado |
| 2 | `r.jina.ai/URL` | Páginas renderizadas con JS, PDFs, extracción más limpia |
| 3 | `firecrawl <url>` | Bypass de anti-bots, sitios bloqueados (403, Cloudflare) |
| 4 | Agente `firecrawl-expert` | Raspado complejo, extracción estructurada |

Consulta [tools/README.md](tools/README.md) para la documentación completa y scripts de instalación.

## Pruebas y Validación

Valida todas las extensiones antes de comprometer:

```bash
cd tests

# Ejecutar validación completa (requiere just)
just test

# O ejecutar directamente
bash validate.sh

# Windows
powershell validate.ps1
```

### Qué se Valida
- Sintaxis de frontmatter YAML
- Campos obligatorios (nombre, descripción)
- Convenciones de nomenclatura (kebab-case)
- Estructura de archivos (agents/*.md, skills/*/SKILL.md)
- Manifiestos de plugin (`.claude-plugin/plugin.json` + `marketplace.json`) vía el comando autoritativo `claude plugin validate`, más una guardia contra un `marketplace.json` suelto en la raíz.

### Tareas Disponibles

```bash
cd tests
just              # Listar todas las tareas
just test         # Ejecutar validación completa
just validate-yaml # Solo YAML
just validate-names # Solo nombres
just stats        # Contar extensiones
just list-agents  # Listar todos los agentes
```

## Continuidad de Sesión

Los comandos `/save` y `/sync` hacen que el estado de la sesión sea **portable**.

**Lo que ya es nativo:** Claude Code recuerda mucho por sí solo. `--resume` y el selector de sesiones restauran el historial de conversación, la auto-memoria escribe un `MEMORY.md` por proyecto con aprendizajes que Claude decide que vale la pena conservar, y los puntos de control `/rewind` te permiten retroceder dentro de una sesión. Todo esto es local de la máquina — según la documentación, los archivos de auto-memoria "no se comparten entre máquinas o entornos de nube" — y recuerda el contexto *para ti*, en un formato que Claude cura.

**Lo que aún falta:** el estado de las tareas. Las tareas (creadas vía TaskCreate, gestionadas vía TaskList/TaskUpdate) tienen alcance de sesión y se eliminan cuando la sesión termina — por diseño. Y nada del estado nativo es algo que puedas comprometer, revisar o entregar a un compañero.

**Lo que `/save` + `/sync` añaden:** un archivo de estado que tú controlas — restauración de tareas, contexto estructurado de git/PR, notas de traspaso explícitas y legibles por humanos, y puente de ID de sesión. Debido a que vive en tu repo, es rastreable por git, compartible en equipo y te sigue entre máquinas. Esto implementa el patrón de [Effective Harnesses for Long-Running Agents](https://www.anthropic.com/engineering/effective-harnesses-for-long-running-agents) de Anthropic:

> "Cada sesión subsiguiente pide al modelo que haga progresos incrementales y luego deje actualizaciones estructuradas".

### Qué persiste vs Qué no

| Característica de Claude Code | ¿Persiste? | Alcance |
|---------------------|-----------|-------|
| Historial de conversación | Sí | Esta máquina (`--resume` / selector de sesiones) |
| Auto-memoria (MEMORY.md) | Sí | Esta máquina, por repo — aprendizajes curados por Claude, no estado de tareas |
| Contexto de CLAUDE.md | Sí | Dondequiera que lo comprometas |
| Tareas | **No** | Eliminadas al finalizar la sesión |
| Estado del Modo Plan | **No** | Solo en memoria |

### Flujo de Sesión

```
Sesión 1:
  /sync                              # Bootstrap + restaurar estado guardado
  [trabajar en tareas]
  /save "Detenido en módulo de auth"     # Escribe session-cache.json + MEMORY.md

Sesión 2:
  [MEMORY.md auto-cargado: "Meta: Auth, Rama: feature/auth, PR: #42"]
  /sync                              # Restauración completa: tareas, plan, git, PR
  → "Sesión anterior: abc123... (claude --resume abc123...)"
  → "En progreso: Refactorización de módulo de Auth"
  → "PR: #42 (claude --from-pr 42)"
```

### ¿Por qué no usar simplemente `--resume` o Auto-Memoria?

| Característica | `--resume` | Auto-memoria | `/save` + `/sync` |
|---------|------------|-------------|-------------------|
| Historial de conversación | Sí | No | No |
| Aprendizajes/preferencias | No | Sí (curado por Claude) | No |
| Tareas | **No** | **No** | Sí |
| Contexto Git/PR | Solo PR (`--from-pr`) | Incidental | Sí (estructurado, detectado por `gh`) |
| Puente de ID de sesión | N/A | No | Sí (sugiere `--resume <id>`) |
| Notas de traspaso explícitas | No | No | Sí |
| Rastreable por Git | No | No | Sí |
| Funciona entre máquinas | No | No (local la máquina) | Sí (si se compromete) |
| Compartición en equipo | No | No | Sí |

**Usa los tres juntos:** `claude --resume` para el contexto de la conversación, auto-memoria para los aprendizajes acumulados, `/sync` para el estado de las tareas y el traspaso. Desde la v3.1, `/save` almacena tu ID de sesión para que `/sync` pueda sugerir el comando `--resume` exacto.

### Esquema de Caché de Sesión (v3.1)

El archivo `.claude/session-cache.json` almacena objetos de tarea completos:

```json
{
  "version": "3.1",
  "session_id": "977c26c9-60fa-4afc-a628-a68f8043b1ab",
  "tasks": [
    {
      "subject": "Título de la tarea",
      "description": "Descripción detallada",
      "activeForm": "Trabajando en la tarea",
      "status": "completed|in_progress|pending",
      "blockedBy": [0, 1]
    }
  ],
  "plan": { "file": "docs/PLAN.md", "goal": "...", "current_step": "...", "progress_percent": 40 },
  "git": { "branch": "main", "last_commit": "abc123", "pr_number": 42, "pr_url": "https://..." },
  "memory": { "synced": true },
  "notes": "Notas de la sesión"
}
```

**Compatibilidad:** `/sync` maneja archivos v3.0 y v3.1 con gracia. Los campos faltantes de v3.1 se tratan como ausentes.

## Actualización

```bash
git pull
```

Luego, vuelve a ejecutar el script de instalación para actualizar tu configuración global de Claude.

## Consejos de Rendimiento

### Búsqueda de Herramientas MCP

Al usar múltiples servidores MCP (Chrome DevTools, Vibe Kanban, etc.), sus definiciones de herramientas consumen contexto. Activa la Búsqueda de Herramientas para cargar herramientas bajo demanda:

```json
// .claude/settings.local.json
{
  "env": {
    "ENABLE_TOOL_SEARCH": "true"
  }
}
```

| Valor | Comportamiento |
|-------|----------|
| `"auto"` | Activa cuando las herramientas MCP > 10% del contexto (predeterminado) |
| `"auto:5"` | Umbral personalizado (5%) |
| `"true"` | Siempre activo (recomendado) |
| `"false"` | Desactivado |

**Requisitos:** Sonnet 4+ u Opus 4+ (Haiku no soportado)

### Presupuesto de Descripción de Habilidades

Con más de 90 habilidades instaladas (solo este plugin incluye 97), las descripciones de las habilidades pueden desbordar el presupuesto de listado. Todos los nombres de las habilidades se listan siempre, pero las descripciones comparten un presupuesto del **1% de la ventana de contexto del modelo** — en caso de desbordamiento, las habilidades menos invocadas pierden sus descripciones primero y **dejan de dispararse automáticamente de forma silenciosa** (la invocación explícita `/nombre` sigue funcionando). La combinación de `description` + `when_to_use` de cada habilidad también se trunca a **1,536 caracteres**, por lo que las frases de activación deben ir al principio.

- **Verificar:** ejecuta `/doctor` — muestra si el presupuesto se está desbordando y qué habilidades se ven afectadas.
- **Solucionar:** degrada o desactiva las habilidades que no uses mediante `skillOverrides` en la configuración (`"on"` / `"name-only"` / `"user-invocable-only"` / `"off"` por habilidad, o `/skills` + `Espacio`). Las habilidades del plugin se gestionan vía `/plugin`.
- **O aumentar el presupuesto:** ajuste `skillListingBudgetFraction` (ej. `0.02`), variable de entorno `SLASH_COMMAND_TOOL_CHAR_BUDGET` para un conteo de caracteres fijo, o `maxSkillDescriptionChars` para el límite por habilidad.

### Habilidades sobre Comandos

La mayor parte de la funcionalidad reside en habilidades en lugar de comandos. Las habilidades obtienen descubrimiento mediante sugerencias slash vía palabras clave de activación y se cargan bajo demanda, reduciendo la carga del contexto. Solo la gestión de sesiones (`/sync`, `/save`) permanece como comandos.

Consulta [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) para el modelo de componentes, y [docs/SKILL-CREATION-PROTOCOL.md](docs/SKILL-CREATION-PROTOCOL.md) para saber cómo construir una nueva habilidad.

## Recursos

- [Claude Code Best Practices](https://www.anthropic.com/engineering/claude-code-best-practices) — Guía oficial de Anthropic
- [Claude Code Plugins](https://claude.com/blog/claude-code-plugins) — Documentación del sistema de plugins
- [Effective Harnesses for Long-Running Agents](https://www.anthropic.com/engineering/effective-harnesses-for-long-running-agents) — El patrón detrás de `/save`

---

*Extiende Claude Code. A tu manera.*
