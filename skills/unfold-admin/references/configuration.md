# Unfold Configuration Reference

## Table of Contents

- [UNFOLD Settings Dict](#unfold-settings-dict)
- [Site Branding](#site-branding)
- [Sidebar Navigation](#sidebar-navigation)
- [Tabs](#tabs)
- [Theming and Colors](#theming-and-colors)
- [Environment Indicator](#environment-indicator)
- [Login Page](#login-page)
- [Command Palette](#command-palette)
- [Custom Styles and Scripts](#custom-styles-and-scripts)
- [Language Switcher](#language-switcher)
- [Complete Settings Example](#complete-settings-example)

## UNFOLD Settings Dict

All configuration lives in `UNFOLD` dict in Django settings:

```python
# settings.py
from django.templatetags.static import static
from django.urls import reverse_lazy
from django.utils.translation import gettext_lazy as _

UNFOLD = {
    # Site identity
    "SITE_TITLE": _("My Admin"),          # <title> tag suffix
    "SITE_HEADER": _("My Admin"),          # sidebar header text
    "SITE_SUBHEADER": _("Admin portal"),   # text below header
    "SITE_URL": "/",                       # header link target

    # Icons and logos
    "SITE_SYMBOL": "dashboard",            # Material Symbols icon name
    "SITE_ICON": lambda request: static("img/icon.svg"),
    "SITE_LOGO": lambda request: static("img/logo.svg"),
    "SITE_FAVICONS": [
        {"rel": "icon", "sizes": "32x32", "type": "image/svg+xml", "href": lambda request: static("img/favicon.svg")},
    ],

    # Light/dark variants for icon and logo
    # "SITE_ICON": {
    #     "light": lambda request: static("img/icon-light.svg"),
    #     "dark": lambda request: static("img/icon-dark.svg"),
    # },

    # UI toggles
    "SHOW_HISTORY": True,          # history button on change form
    "SHOW_VIEW_ON_SITE": True,     # "view on site" button
    "SHOW_BACK_BUTTON": False,     # back button on change forms

    # Theme
    "THEME": None,                 # None (auto), "dark", or "light"
    "BORDER_RADIUS": "6px",        # global border radius

    # Colors (OKLCH format)
    "COLORS": {
        "base": {
            "50": "250 250 250",
            "100": "244 245 245",
            # ... full scale 50-950
            "950": "10 10 10",
        },
        "primary": {
            "50": "250 245 255",
            "100": "243 232 255",
            # ... full scale 50-950
            "950": "59 7 100",
        },
        "font": {
            "subtle-light": "var(--color-base-500)",
            "subtle-dark": "var(--color-base-400)",
            "default-light": "var(--color-base-700)",
            "default-dark": "var(--color-base-200)",
            "important-light": "var(--color-base-900)",
            "important-dark": "var(--color-base-100)",
        },
    },

    # Callbacks
    "ENVIRONMENT": "myapp.utils.environment_callback",
    "ENVIRONMENT_TITLE_PREFIX": None,
    "DASHBOARD_CALLBACK": "myapp.views.dashboard_callback",

    # Login page
    "LOGIN": {
        "image": lambda request: static("img/login-bg.jpg"),
        "redirect_after": "/admin/",
        "form": "myapp.forms.LoginForm",
    },

    # Custom assets
    "STYLES": [lambda request: static("css/custom.css")],
    "SCRIPTS": [lambda request: static("js/custom.js")],

    # Language
    "SHOW_LANGUAGES": False,
    "LANGUAGE_FLAGS": {"en": "US", "de": "DE"},

    # Sidebar
    "SIDEBAR": { ... },   # see below

    # Tabs
    "TABS": [ ... ],      # see below

    # Command palette
    "COMMAND": { ... },    # see below
}
```

## Site Branding

### Icons

Use [Material Symbols](https://fonts.google.com/icons) names for `SITE_SYMBOL` and all navigation icons.

```python
"SITE_SYMBOL": "speed",  # displayed in sidebar when logo not set
```

### Logo vs Icon

- `SITE_LOGO` - larger logo for sidebar header
- `SITE_ICON` - smaller icon (fallback when no logo)
- Both accept a callable `lambda request: url_string` or a dict with `light`/`dark` keys

### Site Dropdown

Add links to the site header dropdown:

```python
"SITE_DROPDOWN": [
    {
        "icon": "description",
        "title": _("Documentation"),
        "link": "https://docs.example.com",
    },
    {
        "icon": "code",
        "title": _("API Reference"),
        "link": "/api/docs/",
    },
],
```

## Sidebar Navigation

```python
"SIDEBAR": {
    "show_search": True,               # search bar in sidebar
    "show_all_applications": True,      # "All Applications" link
    "command_search": True,             # command palette integration
    "navigation": [
        {
            "title": _("Main"),
            "collapsible": False,       # default: not collapsible
            "items": [
                {
                    "title": _("Dashboard"),
                    "icon": "dashboard",
                    "link": reverse_lazy("admin:index"),
                },
                {
                    "title": _("Users"),
                    "icon": "people",
                    "link": reverse_lazy("admin:auth_user_changelist"),
                    "badge": "myapp.utils.users_badge",    # callable returning badge text
                    "badge_variant": "danger",              # primary|success|info|warning|danger
                    "badge_style": "solid",                 # solid|outline
                    "permission": "myapp.utils.perm_check", # callable(request) -> bool
                },
                {
                    "title": _("Products"),
                    "icon": "inventory_2",
                    "active": "myapp.utils.products_active_callback",  # custom active logic
                    "items": [  # nested subitems
                        {
                            "title": _("All Products"),
                            "link": reverse_lazy("admin:shop_product_changelist"),
                        },
                        {
                            "title": _("Categories"),
                            "link": reverse_lazy("admin:shop_category_changelist"),
                        },
                    ],
                },
            ],
        },
        {
            "title": _("Settings"),
            "collapsible": True,
            "items": [ ... ],
        },
    ],
},
```

### Navigation Item Fields

| Field | Type | Description |
|-------|------|-------------|
| `title` | str | Display text |
| `icon` | str | Material Symbols icon name |
| `link` | str/lazy | URL (use `reverse_lazy`) |
| `badge` | str/callable | Badge text or `"dotted_path.to.callback"` |
| `badge_variant` | str | primary, success, info, warning, danger |
| `badge_style` | str | solid, outline |
| `permission` | str/callable | `"dotted_path.to.callback"` returning bool |
| `active` | str/callable | Custom active state logic |
| `items` | list | Nested sub-navigation items |
| `collapsible` | bool | Group-level: allow collapse |

### Badge Callback

```python
def users_badge(request):
    return User.objects.filter(is_active=False).count() or None
```

### Permission Callback

```python
def permission_callback(request):
    return request.user.has_perm("myapp.view_sensitive")
```

### Active Callback

```python
def products_active_callback(request):
    return request.path.startswith("/admin/shop/")
```

## Tabs

Tabs appear above the changelist, linking related models or filtered views:

```python
"TABS": [
    {
        "models": [
            "shop.product",
            "shop.category",
            {"name": "shop.order", "detail": True},  # show tabs on detail/change pages too
        ],
        "items": [
            {
                "title": _("Products"),
                "link": reverse_lazy("admin:shop_product_changelist"),
            },
            {
                "title": _("Categories"),
                "link": reverse_lazy("admin:shop_category_changelist"),
            },
        ],
    },
    {
        "page": "users",  # custom page identifier
        "models": ["auth.user"],
        "items": [
            {
                "title": _("All Users"),
                "link": reverse_lazy("admin:auth_user_changelist"),
                "active": lambda request: "status" not in request.GET,
            },
            {
                "title": _("Active"),
                "link": lambda request: f"{reverse_lazy('admin:auth_user_changelist')}?is_active__exact=1",
            },
            {
                "title": _("Staff"),
                "link": lambda request: f"{reverse_lazy('admin:auth_user_changelist')}?is_staff__exact=1",
            },
        ],
    },
],
```

### Tab Model Formats

Models in the `models` list accept two formats:

```python
"models": [
    "app.model",                          # string: tabs on changelist only
    {"name": "app.model", "detail": True},  # dict: also show tabs on change form
]
```

### Tab Item Fields

| Field | Type | Description |
|-------|------|-------------|
| `title` | str | Tab label |
| `link` | str/callable | URL or `lambda request: url` |
| `permission` | str/callable | Visibility control |
| `active` | callable | `lambda request: bool` for custom active state |

## Theming and Colors

### Color System

Unfold uses OKLCH color space with a 50-950 scale. Override `base` and `primary` palettes:

```python
"COLORS": {
    "base": {
        "50": "250 250 250",
        "100": "245 245 245",
        "200": "229 229 229",
        "300": "212 212 212",
        "400": "163 163 163",
        "500": "115 115 115",
        "600": "82 82 82",
        "700": "64 64 64",
        "800": "38 38 38",
        "900": "23 23 23",
        "950": "10 10 10",
    },
    "primary": {
        "50": "238 242 255",
        "100": "224 231 255",
        "200": "199 210 254",
        "300": "165 180 252",
        "400": "129 140 248",
        "500": "99 102 241",
        "600": "79 70 229",
        "700": "67 56 202",
        "800": "55 48 163",
        "900": "49 46 129",
        "950": "30 27 75",
    },
},
```

### Border Radius

```python
"BORDER_RADIUS": "6px",   # applies globally
```

### Forced Theme

```python
"THEME": "dark",   # disables the light/dark toggle
```

## Environment Indicator

Display a colored badge in the header (e.g., "Development", "Staging"):

```python
"ENVIRONMENT": "myapp.utils.environment_callback",
```

Callback implementation:

```python
def environment_callback(request):
    """Return (name, color_type) or None."""
    if settings.DEBUG:
        return _("Development"), "danger"    # red badge
    if "staging" in request.get_host():
        return _("Staging"), "warning"       # orange badge
    return None  # no badge in production
```

Color types: `"danger"`, `"warning"`, `"info"`, `"success"`.

Optional title prefix:

```python
"ENVIRONMENT_TITLE_PREFIX": _("DEV"),  # prepends to <title>
```

## Login Page

```python
"LOGIN": {
    "image": lambda request: static("img/login-bg.jpg"),
    "redirect_after": "/admin/",
    "form": "myapp.forms.LoginForm",  # custom form class
},
```

## Command Palette

Configure the Ctrl+K / Cmd+K command palette:

```python
"COMMAND": {
    "search_models": True,           # Default: False. Also accepts list/tuple or callback
    # "search_models": ["myapp.mymodel"],           # specific models
    # "search_models": "myapp.utils.search_models_callback",  # callback
    "search_callback": "myapp.utils.search_callback",  # custom search hook
    "show_history": True,            # command history in localStorage
},
```

### Custom Search Callback

```python
from unfold.dataclasses import SearchResult

def search_callback(request, search_term):
    return [
        SearchResult(
            title="Some title",
            description="Extra content",
            link="https://example.com",
            icon="database",
        )
    ]
```

## Custom Styles and Scripts

Load additional CSS/JS files:

```python
"STYLES": [
    lambda request: static("css/admin-overrides.css"),
],
"SCRIPTS": [
    lambda request: static("js/admin-charts.js"),
],
```

## Language Switcher

```python
"SHOW_LANGUAGES": True,
"LANGUAGE_FLAGS": {
    "en": "US",
    "de": "DE",
    "fr": "FR",
},
```

## Complete Settings Example

See the [Formula demo settings](https://github.com/unfoldadmin/formula/blob/main/formula/settings.py) for a production-ready reference.
