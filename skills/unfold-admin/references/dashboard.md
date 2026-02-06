# Dashboard, Sections, and Datasets Reference

## Table of Contents

- [Dashboard Components](#dashboard-components)
- [Dashboard Callback](#dashboard-callback)
- [Sections (Changelist Panels)](#sections)
- [Datasets (Change Form Panels)](#datasets)
- [Template Injection](#template-injection)
- [Custom Dashboard Templates](#custom-dashboard-templates)

## Dashboard Components

### Imports

```python
from unfold.components import BaseComponent, register_component
from django.template.loader import render_to_string
```

### Creating a Component

Components are registered globally and rendered on the admin index page:

```python
@register_component
class ActiveUsersKPI(BaseComponent):
    def get_context_data(self, **kwargs):
        context = super().get_context_data(**kwargs)
        context["children"] = render_to_string("myapp/kpi_card.html", {
            "total": User.objects.filter(is_active=True).count(),
            "label": "Active Users",
            "progress": "positive",    # or "negative"
            "percentage": "+5.2%",
        })
        return context
```

### KPI Card Template Pattern

```html
<!-- templates/myapp/kpi_card.html -->
<div class="flex flex-col gap-1">
    <div class="text-2xl font-bold text-base-900 dark:text-base-100">
        {{ total }}
    </div>
    <div class="flex items-center gap-2">
        <span class="text-sm text-base-500 dark:text-base-400">{{ label }}</span>
        {% if percentage %}
        <span class="text-xs {% if progress == 'positive' %}text-green-600{% else %}text-red-600{% endif %}">
            {{ percentage }}
        </span>
        {% endif %}
    </div>
</div>
```

### Chart Component

Unfold supports Chart.js via custom components:

```python
@register_component
class SalesChartComponent(BaseComponent):
    def get_context_data(self, **kwargs):
        context = super().get_context_data(**kwargs)
        context["data"] = json.dumps({
            "labels": ["Mon", "Tue", "Wed", "Thu", "Fri"],
            "datasets": [{
                "data": [[1, 5], [1, 8], [1, 12], [1, 7], [1, 15]],
                "backgroundColor": "var(--color-primary-600)",
            }],
        })
        return context
```

### Component Rendering

Components are rendered in the admin index template. Customize the index template to control layout:

```html
<!-- templates/admin/index.html -->
{% extends "unfold/layouts/base_simple.html" %}
{% load unfold %}

{% block content %}
<div class="grid grid-cols-1 lg:grid-cols-4 gap-4 mb-8">
    {% component "ActiveUsersKPI" %}{% endcomponent %}
    {% component "RevenueKPI" %}{% endcomponent %}
    {% component "OrdersKPI" %}{% endcomponent %}
    {% component "ConversionKPI" %}{% endcomponent %}
</div>
<div class="grid grid-cols-1 lg:grid-cols-2 gap-4">
    {% component "SalesChartComponent" %}{% endcomponent %}
    {% component "RecentOrdersComponent" %}{% endcomponent %}
</div>
{% endblock %}
```

## Dashboard Callback

Configure in settings:

```python
UNFOLD = {
    "DASHBOARD_CALLBACK": "myapp.views.dashboard_callback",
}
```

The callback prepares template context for the admin index:

```python
# myapp/views.py
def dashboard_callback(request, context):
    """Add extra context to admin dashboard."""
    context.update({
        "custom_variable": "value",
        "stats": get_dashboard_stats(),
    })
    return context
```

## Sections

Sections are panels displayed below the changelist table.

### Imports

```python
from unfold.sections import TableSection, TemplateSection
```

### TableSection

Renders a related model's data as a table:

```python
class RecentOrdersSection(TableSection):
    related_name = "order_set"      # related manager name
    fields = ["id", "total", "status", "custom_field"]
    height = 380                     # fixed height in px

    @admin.display(description=_("Formatted Total"))
    def custom_field(self, instance):
        return f"${instance.total:.2f}"
```

### TemplateSection

Renders a custom template:

```python
class AnalyticsSection(TemplateSection):
    template_name = "myapp/analytics_chart.html"
```

### Registering Sections

```python
class MyAdmin(ModelAdmin):
    list_sections = [RecentOrdersSection, AnalyticsSection]
    list_sections_classes = "lg:grid-cols-2"  # CSS grid layout
```

## Datasets

Datasets embed full mini-admin listings within change forms. Think of them as "related admin views" rendered inside another model's edit page.

### Imports

```python
from unfold.datasets import BaseDataset
from unfold.admin import ModelAdmin
```

### Creating a Dataset

```python
# Step 1: Define a mini-admin for the dataset
class RelatedItemDatasetAdmin(ModelAdmin):
    list_display = ["name", "status", "created_at"]
    search_fields = ["name"]
    actions = ["bulk_approve"]

    def bulk_approve(self, request, queryset):
        queryset.update(status="approved")
        messages.success(request, "Approved.")
        return redirect(request.headers.get("referer"))

    def get_queryset(self, request):
        obj = self.extra_context.get("object")  # parent object
        if not obj:
            return super().get_queryset(request).none()
        return super().get_queryset(request).filter(parent=obj)

# Step 2: Define the dataset
class RelatedItemDataset(BaseDataset):
    model = RelatedItem
    model_admin = RelatedItemDatasetAdmin
    tab = True  # render as tab on change form

# Step 3: Register on the parent admin
class ParentAdmin(ModelAdmin):
    change_form_datasets = [RelatedItemDataset]
```

### Dataset Fields

| Field | Type | Description |
|-------|------|-------------|
| `model` | Model class | The related model |
| `model_admin` | ModelAdmin class | Mini-admin configuration |
| `tab` | bool | Show as tab on change form |

### Key Pattern: Access Parent Object

In the dataset's `model_admin`, access the parent object via `self.extra_context`:

```python
def get_queryset(self, request):
    obj = self.extra_context.get("object")
    if not obj:
        return super().get_queryset(request).none()
    return super().get_queryset(request).filter(owner=obj)
```

## Template Injection

### Changelist Templates

```python
class MyAdmin(ModelAdmin):
    list_before_template = "myapp/list_before.html"  # above table
    list_after_template = "myapp/list_after.html"     # below table
```

### Change Form Templates

```python
class MyAdmin(ModelAdmin):
    change_form_before_template = "myapp/form_before.html"  # above form
    change_form_after_template = "myapp/form_after.html"     # below form
```

### Template Context

Injected templates receive the standard Django admin template context plus the Unfold context. Use `{{ cl }}` for changelist context, `{{ original }}` for the object in change form templates.

```html
<!-- templates/myapp/list_before.html -->
<div class="rounded-lg border border-base-200 dark:border-base-700 p-4 mb-4">
    <h3 class="text-lg font-semibold text-base-900 dark:text-base-100">
        Quick Stats
    </h3>
    <p class="text-base-500 dark:text-base-400">
        Showing {{ cl.result_count }} results
    </p>
</div>
```

## Custom Dashboard Templates

### Override admin/index.html

```html
<!-- templates/admin/index.html -->
{% extends "unfold/layouts/base_simple.html" %}
{% load i18n unfold %}

{% block title %}
    {{ title }} | {{ site_title }}
{% endblock %}

{% block content %}
    {% include "myapp/dashboards.html" %}
{% endblock %}
```

### Dashboard Layout Pattern

```html
<!-- templates/myapp/dashboards.html -->
{% load unfold %}

<!-- KPI Row -->
<div class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-4 mb-6">
    {% component "KPI1" %}{% endcomponent %}
    {% component "KPI2" %}{% endcomponent %}
    {% component "KPI3" %}{% endcomponent %}
    {% component "KPI4" %}{% endcomponent %}
</div>

<!-- Charts Row -->
<div class="grid grid-cols-1 lg:grid-cols-2 gap-4 mb-6">
    {% component "Chart1" %}{% endcomponent %}
    {% component "Chart2" %}{% endcomponent %}
</div>

<!-- Tables Row -->
<div class="grid grid-cols-1 gap-4">
    {% component "RecentActivity" %}{% endcomponent %}
</div>
```

### Tailwind CSS Classes

Unfold uses Tailwind CSS. Common utility patterns for custom templates:

| Pattern | Classes |
|---------|---------|
| Card | `rounded-lg border border-base-200 dark:border-base-700 bg-white dark:bg-base-900 p-4` |
| Heading | `text-lg font-semibold text-base-900 dark:text-base-100` |
| Muted text | `text-sm text-base-500 dark:text-base-400` |
| Grid layout | `grid grid-cols-1 lg:grid-cols-2 gap-4` |
| Flex row | `flex items-center gap-2` |

### Paginator

```python
from unfold.paginator import InfinitePaginator

class MyAdmin(ModelAdmin):
    paginator = InfinitePaginator
    show_full_result_count = False
    list_per_page = 20
```

`InfinitePaginator` provides infinite scroll instead of page numbers.
