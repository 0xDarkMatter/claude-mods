# Resources, Integrations, and Patterns

## Table of Contents

- [Official Resources](#official-resources)
- [Third-Party Integrations](#third-party-integrations)
- [Built-In Template Components](#built-in-template-components)
- [Common Patterns](#common-patterns)
- [Version Compatibility](#version-compatibility)
- [Unfold Studio](#unfold-studio)
- [Community and Learning](#community-and-learning)

## Official Resources

| Resource | URL |
|----------|-----|
| Documentation | https://unfoldadmin.com/docs/ |
| GitHub Repository | https://github.com/unfoldadmin/django-unfold |
| PyPI | https://pypi.org/project/django-unfold/ |
| Live Demo | https://demo.unfoldadmin.com |
| Formula Demo App | https://github.com/unfoldadmin/formula |
| Turbo Boilerplate (Django + Next.js) | https://github.com/unfoldadmin/turbo |
| Material Symbols (Icons) | https://fonts.google.com/icons |
| Discord Community | https://discord.gg/9sQj9MEbNz |
| Blog | https://unfoldadmin.com/blog/ |
| Features Overview | https://unfoldadmin.com/features/ |
| Django Packages | https://djangopackages.org/packages/p/django-unfold/ |

### Formula Demo App

The [Formula](https://github.com/unfoldadmin/formula) demo is the authoritative reference implementation. It demonstrates:
- Every action type (list, row, detail, submit line) with permissions
- All filter classes with custom filters
- Display decorators (header, dropdown, label, boolean)
- Dashboard components with KPI cards and charts
- Datasets embedded in change forms
- Sections (TableSection, TemplateSection)
- Conditional fields, fieldset tabs, inline tabs
- Third-party integrations (celery-beat, guardian, simple-history, import-export, modeltranslation, crispy-forms, djangoql)
- Custom form views and URL registration
- Template injection points
- InfinitePaginator
- Nonrelated inlines

When unsure about implementation, consult `formula/admin.py` and `formula/settings.py` in the Formula repo.

## Third-Party Integrations

Unfold provides styled wrappers for these packages. Use the multiple inheritance pattern:

### Supported Packages

| Package | Unfold Module | What It Provides |
|---------|--------------|------------------|
| django-import-export | `unfold.contrib.import_export` | `ImportForm`, `ExportForm`, `SelectableFieldsExportForm` |
| django-guardian | `unfold.contrib.guardian` | Styled guardian admin integration |
| django-simple-history | `unfold.contrib.simple_history` | Styled history admin |
| django-constance | `unfold.contrib.constance` | Styled constance config admin |
| django-location-field | `unfold.contrib.location_field` | `UnfoldAdminLocationWidget` |
| django-celery-beat | Compatible (requires rewiring) | Unregister/re-register all 5 models |
| django-modeltranslation | Compatible | Mix `TabbedTranslationAdmin` with `ModelAdmin` |
| django-money | `unfold.widgets` | `UnfoldAdminMoneyWidget` |
| djangoql | Compatible | Mix `DjangoQLSearchMixin` with `ModelAdmin` |
| django-json-widget | Compatible | Use Unfold form overrides |
| django-crispy-forms | Compatible | Unfold template pack `unfold_crispy` |

### django-import-export Setup

```python
from import_export.admin import ImportExportModelAdmin, ExportActionModelAdmin
from unfold.contrib.import_export.forms import ImportForm, ExportForm, SelectableFieldsExportForm

@admin.register(MyModel)
class MyModelAdmin(ModelAdmin, ImportExportModelAdmin, ExportActionModelAdmin):
    resource_classes = [MyResource, AnotherResource]
    import_form_class = ImportForm
    export_form_class = SelectableFieldsExportForm  # or ExportForm
```

### django-celery-beat Setup

Requires unregistering and re-registering all celery-beat models:

```python
from django_celery_beat.admin import (
    ClockedScheduleAdmin as BaseClockedScheduleAdmin,
    CrontabScheduleAdmin as BaseCrontabScheduleAdmin,
    PeriodicTaskAdmin as BasePeriodicTaskAdmin,
    PeriodicTaskForm, TaskSelectWidget,
)
from django_celery_beat.models import (
    ClockedSchedule, CrontabSchedule, IntervalSchedule,
    PeriodicTask, SolarSchedule,
)

admin.site.unregister(PeriodicTask)
admin.site.unregister(IntervalSchedule)
admin.site.unregister(CrontabSchedule)
admin.site.unregister(SolarSchedule)
admin.site.unregister(ClockedSchedule)

# Merge TaskSelectWidget with Unfold's select
class UnfoldTaskSelectWidget(UnfoldAdminSelectWidget, TaskSelectWidget):
    pass

class UnfoldPeriodicTaskForm(PeriodicTaskForm):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.fields["task"].widget = UnfoldAdminTextInputWidget()
        self.fields["regtask"].widget = UnfoldTaskSelectWidget()

@admin.register(PeriodicTask)
class PeriodicTaskAdmin(BasePeriodicTaskAdmin, ModelAdmin):
    form = UnfoldPeriodicTaskForm

@admin.register(IntervalSchedule)
class IntervalScheduleAdmin(ModelAdmin):
    pass

@admin.register(CrontabSchedule)
class CrontabScheduleAdmin(BaseCrontabScheduleAdmin, ModelAdmin):
    pass

@admin.register(SolarSchedule)
class SolarScheduleAdmin(ModelAdmin):
    pass

@admin.register(ClockedSchedule)
class ClockedScheduleAdmin(BaseClockedScheduleAdmin, ModelAdmin):
    pass
```

### django-crispy-forms Setup

```python
# settings.py
CRISPY_TEMPLATE_PACK = "unfold_crispy"
CRISPY_ALLOWED_TEMPLATE_PACKS = ["unfold_crispy"]
```

In templates: `{% crispy form "unfold_crispy" %}`. For formsets, use `"unfold_crispy/layout/table_inline_formset.html"` as the FormHelper template.

### django-constance Setup

```python
INSTALLED_APPS = [
    "unfold.contrib.constance",
    "constance",
]
```

Use `UNFOLD_CONSTANCE_ADDITIONAL_FIELDS` from `unfold.contrib.constance.settings` to define custom field widgets for constance config values.

### Multiple Inheritance Pattern

Order matters - Unfold `ModelAdmin` should be last:

```python
# Correct order: specific mixins first, Unfold ModelAdmin last
@admin.register(MyModel)
class MyModelAdmin(DjangoQLSearchMixin, SimpleHistoryAdmin, GuardedModelAdmin, ModelAdmin):
    pass
```

## Built-In Template Components

Unfold ships with reusable template components for dashboards and custom pages. Use with Django's `{% include %}` tag:

### Component Templates

| Component | Template Path | Key Variables |
|-----------|--------------|---------------|
| Button | `unfold/components/button.html` | `class`, `name`, `href`, `submit` |
| Card | `unfold/components/card.html` | `class`, `title`, `footer`, `label`, `icon` |
| Bar Chart | `unfold/components/chart/bar.html` | `class`, `data` (JSON), `height`, `width` |
| Line Chart | `unfold/components/chart/line.html` | `class`, `data` (JSON), `height`, `width` |
| Cohort | `unfold/components/cohort.html` | `data` |
| Container | `unfold/components/container.html` | `class` |
| Flex | `unfold/components/flex.html` | `class`, `col` |
| Icon | `unfold/components/icon.html` | `class` |
| Navigation | `unfold/components/navigation.html` | `class`, `items` |
| Progress | `unfold/components/progress.html` | `class`, `value`, `title`, `description` |
| Separator | `unfold/components/separator.html` | `class` |
| Table | `unfold/components/table.html` | `table`, `card_included`, `striped` |
| Text | `unfold/components/text.html` | `class` |
| Title | `unfold/components/title.html` | `class` |
| Tracker | `unfold/components/tracker.html` | `class`, `data` |
| Layer | `unfold/components/layer.html` | Wrapper component |

### Using Components in Templates

```html
{% load unfold %}

{# KPI Card #}
{% component "MyKPIComponent" %}{% endcomponent %}

{# Include with variables #}
{% include "unfold/components/card.html" with title="Revenue" icon="payments" %}
    <div class="text-2xl font-bold">$42,000</div>
{% endinclude %}

{# Chart with JSON data #}
{% include "unfold/components/chart/bar.html" with data=chart_data height=300 %}
```

### Chart Data Format (Chart.js)

```python
import json

chart_data = json.dumps({
    "labels": ["Jan", "Feb", "Mar", "Apr"],
    "datasets": [{
        "label": "Revenue",
        "data": [4000, 5200, 4800, 6100],
        "backgroundColor": "var(--color-primary-600)",
    }],
})
```

## Common Patterns

### Pattern 1: Proxy Model for Alternate Views

Use Django proxy models to create different admin views of the same data:

```python
# models.py
class ActiveUser(User):
    class Meta:
        proxy = True

# admin.py
@admin.register(ActiveUser)
class ActiveUserAdmin(ModelAdmin):
    def get_queryset(self, request):
        return super().get_queryset(request).filter(is_active=True)
```

### Pattern 2: Custom Admin Site

```python
# sites.py
from unfold.sites import UnfoldAdminSite

class MyAdminSite(UnfoldAdminSite):
    site_header = "My Admin"
    site_title = "My Admin"

admin_site = MyAdminSite(name="myadmin")

# urls.py
urlpatterns = [
    path("admin/", admin_site.urls),
]
```

### Pattern 3: Optimized Querysets

Always optimize querysets for list views with annotations and prefetches:

```python
def get_queryset(self, request):
    return (
        super().get_queryset(request)
        .annotate(total_points=Sum("standing__points"))
        .select_related("author", "category")
        .prefetch_related("tags", "teams")
    )
```

### Pattern 4: Conditional Registration

Conditionally register admin classes based on installed apps:

```python
if "django_celery_beat" in settings.INSTALLED_APPS:
    @admin.register(PeriodicTask)
    class PeriodicTaskAdmin(BasePeriodicTaskAdmin, ModelAdmin):
        pass
```

### Pattern 5: Dynamic Sidebar Badges

```python
# utils.py
def pending_orders_badge(request):
    count = Order.objects.filter(status="pending").count()
    return str(count) if count > 0 else None
```

```python
# settings.py
"SIDEBAR": {
    "navigation": [{
        "items": [{
            "title": "Orders",
            "badge": "myapp.utils.pending_orders_badge",
            "badge_variant": "danger",
        }],
    }],
}
```

### Pattern 6: Environment-Aware Configuration

```python
def environment_callback(request):
    if settings.DEBUG:
        return _("Development"), "danger"
    host = request.get_host()
    if "staging" in host:
        return _("Staging"), "warning"
    if "demo" in host:
        return _("Demo"), "info"
    return None  # production - no badge
```

### Pattern 7: Admin Actions with Intermediate Forms

For actions that need user input before executing:

```python
@action(description=_("Schedule Export"), url_path="schedule-export")
def schedule_export(self, request, object_id):
    obj = get_object_or_404(self.model, pk=object_id)

    class ExportForm(forms.Form):
        format = forms.ChoiceField(
            choices=[("csv", "CSV"), ("xlsx", "Excel")],
            widget=UnfoldAdminSelectWidget,
        )
        date_range = forms.SplitDateTimeField(
            widget=UnfoldAdminSplitDateTimeWidget,
            required=False,
        )

    form = ExportForm(request.POST or None)
    if request.method == "POST" and form.is_valid():
        # schedule export task
        messages.success(request, "Export scheduled.")
        return redirect(reverse_lazy("admin:myapp_mymodel_change", args=[object_id]))

    return render(request, "myapp/export_form.html", {
        "form": form,
        "object": obj,
        "title": f"Schedule Export for {obj}",
        **self.admin_site.each_context(request),
    })
```

### Pattern 8: Full-Width Changelist with Sheet Filters

```python
class MyAdmin(ModelAdmin):
    list_fullwidth = True       # no sidebar, full width
    list_filter_submit = True   # submit button
    list_filter_sheet = True    # filters in sliding sheet panel
```

### Pattern 9: Sortable Model with Hidden Weight Field

```python
# models.py
class MenuItem(models.Model):
    name = models.CharField(max_length=100)
    weight = models.PositiveIntegerField(default=0)

    class Meta:
        ordering = ["weight"]

# admin.py
class MenuItemAdmin(ModelAdmin):
    ordering_field = "weight"
    hide_ordering_field = True  # hides weight column from list_display
```

## Version Compatibility

| django-unfold | Python | Django |
|---------------|--------|--------|
| 0.78.x (latest) | >=3.10, <4.0 | 4.2, 5.0, 5.1, 5.2, 6.0 |

### Required INSTALLED_APPS Order

```python
INSTALLED_APPS = [
    # Unfold MUST come before django.contrib.admin
    "unfold",
    "unfold.contrib.filters",     # optional
    "unfold.contrib.forms",       # optional
    "unfold.contrib.inlines",     # optional
    "unfold.contrib.import_export",  # optional
    # Then Django
    "django.contrib.admin",
    "django.contrib.auth",
    # ...
]
```

## Unfold Studio

Unfold Studio is the commercial offering built on top of the open-source django-unfold:

- **Pre-built dashboard templates** - ready-made KPI layouts
- **Additional components** - extended component library
- **Studio settings** - `UNFOLD["STUDIO"]` with options like `header_sticky`, `layout_style` (boxed), `header_variant`, `sidebar_style` (minimal), `sidebar_variant`, `site_banner`

Studio settings (all optional, only available with Studio license):

```python
UNFOLD = {
    "STUDIO": {
        "header_sticky": True,
        "layout_style": "boxed",
        "header_variant": "dark",
        "sidebar_style": "minimal",
        "sidebar_variant": "dark",
        "site_banner": "Important announcement",
    },
}
```

## Community and Learning

### Official Blog Posts

| Title | Topic |
|-------|-------|
| Making Django admin models readonly with custom mixins | Readonly patterns |
| Migrating existing Django admin interface to Unfold | Migration guide |
| Creating modal windows with Alpine.js and HTMX | UI techniques |
| Turn Django admin into full-fledged dashboard with Unfold | Dashboard setup |
| Dark mode toggle in Django with TailwindCSS and Alpine.js | Theming |
| Configuring custom AWS S3 storage backends in django-storages | Storage |
| Customizing and loading your own Django admin site | Custom admin sites |
| Setting up a new Django project with Poetry and Docker | Project setup |

All at https://unfoldadmin.com/blog/

### Community Tutorials

| Title | Author | URL |
|-------|--------|-----|
| Django Unfold Tutorial: A Better Admin Panel | Bastiaan Rudolf | https://medium.com/@bastiaanrudolf/django-unfold-tutorial-a-better-admin-panel-e0b36e03e653 |
| Getting Started with Django Unfold | Mehedi Khan | https://medium.com/django-unleashed/getting-started-with-django-unfold-a-modern-ui-for-django-admin-aeb8be63bd0a |
| Simplify Your Django Admin with django-unfold | eshat002 | https://dev.to/eshat002/simplify-your-django-admin-with-django-unfold-5g16 |
| Custom Django Unfold Admin Dashboard | thalida | https://www.thalida.com/guides/post/custom-django-unfold-admin-dashboard |

### Other References

- **Formula demo walkthrough**: Study `formula/admin.py` for real-world patterns
- **GitHub Discussions**: https://github.com/unfoldadmin/django-unfold/discussions
- **Django Admin Theme Roundup**: https://www.djangoproject.com/weblog/2025/apr/18/admin-theme-roundup/
- **RTL Support**: https://pypi.org/project/django-unfold-rtl/ (community fork)

### Tips from the Community

1. **Always use `list_filter_submit = True`** when using input-based filters (text, numeric, date) - without it, filters trigger on every keystroke
2. **Prefetch/select_related in get_queryset** - Unfold's rich display decorators (header, dropdown) make this critical for performance
3. **Use `compressed_fields = True`** for dense forms - reduces vertical space significantly
4. **Action permissions use AND logic** - all listed permissions must be satisfied
5. **InfinitePaginator + show_full_result_count=False** - recommended for large datasets
6. **Tab ordering follows fieldset/inline order** - fieldset tabs appear first, then inline tabs
7. **Conditional fields use Alpine.js expressions** - field names map directly to form field names
8. **Sidebar badge callbacks are called on every request** - keep them fast, consider caching
9. **Unfold ModelAdmin must come LAST** in multiple inheritance - `class MyAdmin(MixinA, MixinB, ModelAdmin):`
10. **`formfield_overrides` are automatic** - Unfold maps all standard Django fields to styled widgets by default; only override when you need a *different* widget (e.g., switch, WYSIWYG)
11. **`list_filter_sheet = True` requires `list_filter_submit = True`** - the sheet panel needs the submit button to function
12. **Nonrelated inlines require `unfold.contrib.inlines`** in INSTALLED_APPS - forgetting this is a common source of import errors
13. **Action `url_path` must be unique** per admin class - duplicate paths cause silent routing failures
14. **`readonly_preprocess_fields`** accepts callables like `{"field": "html"}` to render HTML in readonly fields, or custom functions
15. **`add_fieldsets`** attribute works like Django's UserAdmin - define separate fieldsets for the add form vs. the change form
16. **Fieldset tabs + `gettext_lazy`**: Tab CSS class detection can break when combined with lazy translation - test tab switching after adding i18n
17. **Dataset pagination resets focus**: Navigating paginated datasets inside tabs may jump back to the General tab
18. **`warn_unsaved_form` + `ordering_field`**: These conflict in TabularInline - unsaved warning fires on drag-to-reorder
19. **Releases every 2-3 weeks** - pin your version in production; Unfold moves fast and breaking changes do occur between minor versions
