# Widgets, Inlines, and Forms Reference

## Table of Contents

- [Widget Classes](#widget-classes)
- [Widget Override Patterns](#widget-override-patterns)
- [Contrib Widgets](#contrib-widgets)
- [Inline Classes](#inline-classes)
- [Nonrelated Inlines](#nonrelated-inlines)
- [Inline Configuration](#inline-configuration)
- [User Forms](#user-forms)
- [Custom Form Fields](#custom-form-fields)

## Widget Classes

All from `unfold.widgets`:

### Text and Input Widgets

| Widget | Replaces | Notes |
|--------|----------|-------|
| `UnfoldAdminTextInputWidget` | `AdminTextInputWidget` | Supports prefix/suffix icons |
| `UnfoldAdminURLInputWidget` | `AdminURLFieldWidget` | URL-specific styling |
| `UnfoldAdminEmailInputWidget` | `AdminEmailInputWidget` | Email input |
| `UnfoldAdminColorInputWidget` | `AdminTextInputWidget` | Color picker (`type="color"`) |
| `UnfoldAdminUUIDInputWidget` | `AdminUUIDInputWidget` | UUID input |
| `UnfoldAdminPasswordWidget` | `PasswordInput` | Password with `render_value` param |
| `UnfoldAdminPasswordToggleWidget` | `PasswordInput` | Password with visibility toggle |
| `UnfoldAdminIntegerRangeWidget` | `MultiWidget` | Two-input range widget |

### Textarea Widgets

| Widget | Notes |
|--------|-------|
| `UnfoldAdminTextareaWidget` | Standard textarea |
| `UnfoldAdminExpandableTextareaWidget` | Starts at 2 rows, expands |

### Number Widgets

| Widget | Replaces |
|--------|----------|
| `UnfoldAdminIntegerFieldWidget` | `AdminIntegerFieldWidget` |
| `UnfoldAdminDecimalFieldWidget` | `AdminIntegerFieldWidget` |
| `UnfoldAdminBigIntegerFieldWidget` | `AdminBigIntegerFieldWidget` |

### Select Widgets

| Widget | Notes |
|--------|-------|
| `UnfoldAdminSelectWidget` | Basic styled select |
| `UnfoldAdminSelect2Widget` | Select2 with search (includes jQuery/Select2 JS) |
| `UnfoldAdminSelectMultipleWidget` | Multi-select |
| `UnfoldAdminSelect2MultipleWidget` | Select2 multi-select with search |
| `UnfoldAdminNullBooleanSelectWidget` | Yes/No/Unknown select |
| `UnfoldAdminRadioSelectWidget` | Radio buttons (VERTICAL default) |
| `UnfoldAdminCheckboxSelectMultiple` | Checkbox group |

### Boolean Widgets

| Widget | Notes |
|--------|-------|
| `UnfoldBooleanWidget` | Standard checkbox |
| `UnfoldBooleanSwitchWidget` | Toggle switch |

### Date/Time Widgets

| Widget | Notes |
|--------|-------|
| `UnfoldAdminDateWidget` | Date picker |
| `UnfoldAdminSingleDateWidget` | Simple date input |
| `UnfoldAdminTimeWidget` | Time picker |
| `UnfoldAdminSingleTimeWidget` | Simple time input |
| `UnfoldAdminSplitDateTimeWidget` | Separate date + time inputs |
| `UnfoldAdminSplitDateTimeVerticalWidget` | Vertical layout with labels |

### File Widgets

| Widget | Notes |
|--------|-------|
| `UnfoldAdminImageFieldWidget` | Image upload with preview |
| `UnfoldAdminFileFieldWidget` | File upload (compact) |
| `UnfoldAdminImageSmallFieldWidget` | Small image upload |

### Relational Widgets

| Widget | Notes |
|--------|-------|
| `UnfoldRelatedFieldWidgetWrapper` | Styled related field wrapper |
| `UnfoldForeignKeyRawIdWidget` | Raw ID for ForeignKey |
| `UnfoldAdminAutocompleteWidget` | Autocomplete select |
| `UnfoldAdminMultipleAutocompleteWidget` | Autocomplete multi-select |

### Third-Party Integration Widgets

| Widget | Requires |
|--------|----------|
| `UnfoldAdminMoneyWidget` | `django-money` |
| `UnfoldAdminLocationWidget` | `django-location-field` |

### Autocomplete Field Classes

For custom autocomplete views (beyond Django's built-in `autocomplete_fields`):

```python
from unfold.fields import (
    UnfoldAdminAutocompleteModelChoiceField,        # single select
    UnfoldAdminMultipleAutocompleteModelChoiceField, # multi select
)
```

These are form **fields** (not widgets) - use them in custom forms when you need autocomplete with a custom `BaseAutocompleteView` backend.

## Automatic Widget Mapping

Unfold automatically applies styled widgets to all standard Django fields. You do NOT need `formfield_overrides` for basic field types - they're handled by default. This mapping shows what Unfold applies behind the scenes:

| Django Field | Unfold Widget (auto-applied) |
|-------------|------------------------------|
| `CharField` | `UnfoldAdminTextInputWidget` |
| `TextField` | `UnfoldAdminTextareaWidget` |
| `IntegerField` | `UnfoldAdminIntegerFieldWidget` |
| `DecimalField` | `UnfoldAdminDecimalFieldWidget` |
| `BigIntegerField` | `UnfoldAdminBigIntegerFieldWidget` |
| `BooleanField` | `UnfoldBooleanWidget` |
| `NullBooleanField` | `UnfoldAdminNullBooleanSelectWidget` |
| `DateField` | `UnfoldAdminDateWidget` |
| `TimeField` | `UnfoldAdminTimeWidget` |
| `DateTimeField` | `UnfoldAdminSplitDateTimeWidget` |
| `EmailField` | `UnfoldAdminEmailInputWidget` |
| `URLField` | `UnfoldAdminURLInputWidget` |
| `UUIDField` | `UnfoldAdminUUIDInputWidget` |
| `ForeignKey` | `UnfoldAdminSelectWidget` (or autocomplete) |
| `ManyToManyField` | `UnfoldAdminSelectMultipleWidget` |
| `FileField` | `UnfoldAdminFileFieldWidget` |
| `ImageField` | `UnfoldAdminImageFieldWidget` |

Only use `formfield_overrides` when you want to **change** from the default (e.g., `BooleanField` to `UnfoldBooleanSwitchWidget`, or `TextField` to `WysiwygWidget`).

## Widget Override Patterns

### Method 1: formfield_overrides

Apply widgets to all fields of a type (overrides the defaults above):

```python
from django.db import models
from unfold.widgets import (
    UnfoldAdminTextInputWidget, UnfoldBooleanSwitchWidget,
    UnfoldAdminImageFieldWidget, UnfoldAdminSelect2Widget,
)
from unfold.contrib.forms.widgets import WysiwygWidget

class MyAdmin(ModelAdmin):
    formfield_overrides = {
        models.TextField: {"widget": WysiwygWidget},
        models.ImageField: {"widget": UnfoldAdminImageFieldWidget},
        models.BooleanField: {"widget": UnfoldBooleanSwitchWidget},
    }
```

### Method 2: get_form() Override

Apply widgets to specific fields:

```python
def get_form(self, request, obj=None, change=False, **kwargs):
    form = super().get_form(request, obj, change, **kwargs)
    form.base_fields["color"].widget = UnfoldAdminColorInputWidget()
    form.base_fields["name"].widget = UnfoldAdminTextInputWidget(attrs={
        "prefix_icon": "search",
        "suffix_icon": "check",
    })
    return form
```

### Method 3: Custom ModelForm

Full control with a custom form class:

```python
class MyModelForm(forms.ModelForm):
    flags = forms.MultipleChoiceField(
        choices=[("A", "Option A"), ("B", "Option B")],
        widget=UnfoldAdminCheckboxSelectMultiple,
        required=False,
    )
    custom_select = forms.ChoiceField(
        choices=[("show", "Show"), ("hide", "Hide")],
        widget=UnfoldAdminSelect2Widget,
    )

class MyAdmin(ModelAdmin):
    form = MyModelForm
```

### Text Input with Icons

```python
UnfoldAdminTextInputWidget(attrs={
    "prefix_icon": "search",     # Material Symbols icon before input
    "suffix_icon": "euro",       # Material Symbols icon after input
})
```

Or set after init:

```python
def __init__(self, *args, **kwargs):
    super().__init__(*args, **kwargs)
    self.fields["name"].widget.attrs.update({
        "prefix_icon": "person",
        "suffix_icon": "verified",
    })
```

## Contrib Widgets

### WYSIWYG Editor

Requires `unfold.contrib.forms` in `INSTALLED_APPS`:

```python
from unfold.contrib.forms.widgets import WysiwygWidget

class MyAdmin(ModelAdmin):
    formfield_overrides = {
        models.TextField: {"widget": WysiwygWidget},
    }
```

Uses the Trix editor. The field stores HTML content.

### Array Widget

For PostgreSQL `ArrayField`:

```python
from unfold.contrib.forms.widgets import ArrayWidget

class MyAdmin(ModelAdmin):
    formfield_overrides = {
        ArrayField: {"widget": ArrayWidget},
    }

    # With choices (requires get_form override)
    def get_form(self, request, obj=None, change=False, **kwargs):
        form = super().get_form(request, obj, change, **kwargs)
        form.base_fields["tags"].widget = ArrayWidget(choices=TagChoices)
        return form
```

## Inline Classes

### Imports

```python
from unfold.admin import TabularInline, StackedInline, GenericStackedInline
from unfold.contrib.inlines.admin import NonrelatedStackedInline, NonrelatedTabularInline
```

### Basic Inline

```python
class OrderItemInline(TabularInline):
    model = OrderItem
    fields = ["product", "quantity", "price"]
    extra = 1
    show_change_link = True
```

### Inline as Tab

```python
class OrderItemInline(TabularInline):
    model = OrderItem
    tab = True  # renders as a tab instead of inline block
```

### Paginated Inline

```python
class CommentInline(StackedInline):
    model = Comment
    per_page = 10  # paginate after 10 items
```

### Sortable Inline (Drag-to-Reorder)

```python
class MenuItemInline(TabularInline):
    model = MenuItem
    ordering_field = "weight"  # integer field for sort order
    ordering = ["weight"]
```

The model needs an integer field (typically `weight` or `order`) that stores position.

### Collapsible Inline

```python
class NoteInline(StackedInline):
    model = Note
    collapsible = True
    classes = ["collapse"]  # Django's built-in collapse also works
```

### Hide Title

```python
class StandingInline(StackedInline):
    model = Standing
    hide_title = True
```

### Custom Inline Title

Override the default inline title by adding `get_inline_title()` to the model:

```python
# models.py
class RelatedModel(models.Model):
    name = models.CharField(max_length=100)

    def get_inline_title(self):
        return f"Custom: {self.name}"
```

### Combined Example

```python
class OrderItemInline(TabularInline):
    model = OrderItem
    tab = True
    per_page = 5
    ordering_field = "weight"
    hide_title = True
    collapsible = True
    autocomplete_fields = ["product"]
    show_change_link = True
    extra = 0
    max_num = 20
```

## Nonrelated Inlines

Display models without a direct ForeignKey relationship:

```python
from unfold.contrib.inlines.admin import NonrelatedStackedInline

class RecentOrdersInline(NonrelatedStackedInline):
    model = Order
    fields = ["id", "total", "status"]
    extra = 0
    tab = True
    per_page = 10

    def get_form_queryset(self, obj):
        """Return queryset for the inline based on parent obj."""
        return self.model.objects.filter(customer__user=obj).order_by("-created_at")

    def save_new_instance(self, parent, instance):
        """Define how to save new instances."""
        instance.customer = parent.customer
```

Requires `unfold.contrib.inlines` in `INSTALLED_APPS`.

### Generic Inlines

For GenericForeignKey relationships:

```python
from unfold.admin import GenericStackedInline

class TagInline(GenericStackedInline):
    model = Tag
```

## Inline Configuration

### Full Attribute Reference

| Attribute | Type | Default | Description |
|-----------|------|---------|-------------|
| `tab` | bool | False | Render as tab |
| `per_page` | int | None | Items per page (pagination) |
| `ordering_field` | str | None | Field for drag-to-reorder |
| `hide_title` | bool | False | Hide inline heading |
| `collapsible` | bool | False | Allow collapse/expand |
| Standard Django inline attributes also apply |

## User Forms

Unfold provides styled versions of Django's user admin forms:

```python
from unfold.forms import AdminPasswordChangeForm, UserChangeForm, UserCreationForm

@admin.register(User)
class UserAdmin(BaseUserAdmin, ModelAdmin):
    form = UserChangeForm
    add_form = UserCreationForm
    change_password_form = AdminPasswordChangeForm
```

## Readonly Field Processing

Transform readonly field display using `readonly_preprocess_fields`:

```python
class MyAdmin(ModelAdmin):
    readonly_preprocess_fields = {
        "description": "html",      # render as HTML (not escaped)
        "metadata": "json",         # pretty-printed JSON
        "avatar": "image",          # render as image thumbnail
        "document": "file",         # render as file download link
        "config": lambda content: f"<pre>{content}</pre>",  # custom callable
    }
```

Built-in preprocessors: `"html"`, `"json"`, `"image"`, `"file"`. Pass a callable for custom transformations.

## Custom Form Fields

### Crispy Forms Integration

Unfold supports django-crispy-forms for custom action forms and standalone pages. Create views that extend Unfold's base templates for consistent styling:

```python
from django.views.generic import FormView

class CustomFormView(FormView):
    template_name = "myapp/custom_form.html"
    model_admin = None  # set when registering URL

    def get_context_data(self, **kwargs):
        context = super().get_context_data(**kwargs)
        context.update(self.model_admin.admin_site.each_context(self.request))
        return context
```

Register via `get_urls()`:

```python
def get_urls(self):
    return super().get_urls() + [
        path("custom/", self.admin_site.admin_view(
            CustomFormView.as_view(model_admin=self)
        ), name="custom_form"),
    ]
```

## Custom Pages

Use `UnfoldModelAdminViewMixin` for class-based views that integrate with Unfold's layout:

```python
from django.views.generic import TemplateView
from unfold.views import UnfoldModelAdminViewMixin

class MyCustomPage(UnfoldModelAdminViewMixin, TemplateView):
    title = "Custom Page"
    permission_required = ()  # tuple of required permissions
    template_name = "myapp/custom_page.html"
```

Register via `get_urls()` with `model_admin=self`:

```python
def get_urls(self):
    view = self.admin_site.admin_view(
        MyCustomPage.as_view(model_admin=self)
    )
    return super().get_urls() + [
        path("custom-page/", view, name="custom_page"),
    ]
```

## Custom Admin Sites

Override the default admin site for full control:

```python
from unfold.sites import UnfoldAdminSite

class CustomAdminSite(UnfoldAdminSite):
    pass

custom_site = CustomAdminSite(name="custom_admin")
```

Register models with `site=`:

```python
@admin.register(MyModel, site=custom_site)
class MyModelAdmin(ModelAdmin):
    pass
```

To override the default admin site globally, use `BasicAppConfig`:

```python
# settings.py
INSTALLED_APPS = [
    "unfold.apps.BasicAppConfig",  # NOT just "unfold"
    "django.contrib.admin",
]

# apps.py
from django.contrib.admin.apps import AdminConfig

class MyAdminConfig(AdminConfig):
    default_site = "myproject.sites.CustomAdminSite"
```

## Key Import Paths

Quick reference for all major Unfold imports:

```python
# Core
from unfold.admin import ModelAdmin, StackedInline, TabularInline, GenericStackedInline
from unfold.sites import UnfoldAdminSite
from unfold.views import UnfoldModelAdminViewMixin

# Decorators and enums
from unfold.decorators import display, action
from unfold.enums import ActionVariant

# Forms
from unfold.forms import AdminPasswordChangeForm, UserChangeForm, UserCreationForm

# Dashboard
from unfold.components import BaseComponent, register_component
from unfold.datasets import BaseDataset
from unfold.sections import TableSection, TemplateSection
from unfold.paginator import InfinitePaginator

# Command palette
from unfold.dataclasses import SearchResult

# Filters
from unfold.contrib.filters.admin import (
    TextFilter, DropdownFilter, MultipleDropdownFilter,
    ChoicesDropdownFilter, MultipleChoicesDropdownFilter,
    RelatedDropdownFilter, MultipleRelatedDropdownFilter,
    RelatedCheckboxFilter, ChoicesCheckboxFilter, AllValuesCheckboxFilter,
    BooleanRadioFilter, CheckboxFilter, AutocompleteSelectMultipleFilter,
    RangeNumericFilter, SingleNumericFilter, SliderNumericFilter,
    RangeNumericListFilter, RangeDateFilter, RangeDateTimeFilter,
)

# Contrib widgets
from unfold.contrib.forms.widgets import ArrayWidget, WysiwygWidget
from unfold.contrib.inlines.admin import NonrelatedStackedInline, NonrelatedTabularInline
from unfold.contrib.import_export.forms import ExportForm, ImportForm, SelectableFieldsExportForm
```
