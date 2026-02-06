# Actions, Display Decorators, and Filters Reference

## Table of Contents

- [Action System](#action-system)
- [Display Decorator](#display-decorator)
- [Filter Classes](#filter-classes)
- [Custom Filters](#custom-filters)

## Action System

### Imports

```python
from unfold.decorators import action
from unfold.enums import ActionVariant
```

### @action Decorator Parameters

| Parameter | Type | Description |
|-----------|------|-------------|
| `description` | str | Button label text |
| `icon` | str | Material Symbols icon name |
| `variant` | ActionVariant | Button color/style |
| `permissions` | list[str] | Required permission names |
| `url_path` | str | Custom URL path segment |
| `attrs` | dict | Extra HTML attributes |

### ActionVariant Enum

```python
from unfold.enums import ActionVariant

ActionVariant.DEFAULT   # neutral
ActionVariant.PRIMARY   # primary color
ActionVariant.SUCCESS   # green
ActionVariant.INFO      # blue
ActionVariant.WARNING   # orange
ActionVariant.DANGER    # red
```

### Four Action Types

Each type has a different method signature and registration attribute:

#### 1. List Actions (Global)

Appear at top of changelist. No object context.

```python
class MyAdmin(ModelAdmin):
    actions_list = ["rebuild_index"]

    @action(description=_("Rebuild Index"), icon="sync", variant=ActionVariant.PRIMARY)
    def rebuild_index(self, request):
        # perform global operation
        messages.success(request, _("Index rebuilt."))
        return redirect(request.headers["referer"])
```

#### 2. Row Actions

Per-row buttons in changelist. Receive `object_id`.

```python
class MyAdmin(ModelAdmin):
    actions_row = ["approve_item"]

    @action(description=_("Approve"), url_path="approve-item")
    def approve_item(self, request, object_id):
        obj = self.model.objects.get(pk=object_id)
        obj.approved = True
        obj.save()
        messages.success(request, f"Approved {obj}")
        return redirect(
            request.headers.get("referer")
            or reverse_lazy("admin:myapp_mymodel_changelist")
        )
```

#### 3. Detail Actions

Buttons on change form toolbar. Receive `object_id`.

```python
class MyAdmin(ModelAdmin):
    actions_detail = ["send_notification"]

    @action(
        description=_("Send Notification"),
        url_path="send-notification",
        permissions=["send_notification"],
    )
    def send_notification(self, request, object_id):
        obj = get_object_or_404(self.model, pk=object_id)
        # can render a custom form page
        return render(request, "myapp/notification_form.html", {
            "object": obj,
            **self.admin_site.each_context(request),
        })

    def has_send_notification_permission(self, request, object_id=None):
        return request.user.has_perm("myapp.send_notification")
```

#### 4. Submit Line Actions

Execute during form save. Receive the model instance `obj`.

```python
class MyAdmin(ModelAdmin):
    actions_submit_line = ["save_and_publish"]

    @action(description=_("Save & Publish"), permissions=["publish"])
    def save_and_publish(self, request, obj):
        obj.published = True
        messages.success(request, f"Published {obj}")

    def has_publish_permission(self, request, obj=None):
        return request.user.has_perm("myapp.publish_item")
```

### Action Groups (Dropdown Menus)

Group multiple actions under a dropdown button:

```python
actions_list = [
    "primary_action",          # standalone button
    {
        "title": _("More Actions"),
        "variant": ActionVariant.PRIMARY,
        "items": [
            "action_two",
            "action_three",
            "action_four",
        ],
    },
]

actions_detail = [
    "main_detail_action",
    {
        "title": _("More"),
        "items": ["detail_action_a", "detail_action_b"],
    },
]
```

### Permission System

Two approaches work together:

```python
# Method 1: Method-based (custom logic)
@action(permissions=["can_export"])
def export_data(self, request):
    pass

def has_can_export_permission(self, request):
    return request.user.groups.filter(name="Exporters").exists()

# Method 2: Django built-in permissions
@action(permissions=["myapp.export_data", "auth.view_user"])
def export_with_django_perms(self, request):
    pass
```

When multiple permissions are listed, ALL must be satisfied (AND logic).

### Action with Custom Form

Render an intermediate form page from a detail action:

```python
@action(description=_("Action with Form"), url_path="custom-form")
def action_with_form(self, request, object_id):
    obj = get_object_or_404(self.model, pk=object_id)

    class ActionForm(forms.Form):
        note = forms.CharField(widget=UnfoldAdminTextInputWidget)
        date = forms.SplitDateTimeField(widget=UnfoldAdminSplitDateTimeWidget)

    form = ActionForm(request.POST or None)

    if request.method == "POST" and form.is_valid():
        # process form
        messages.success(request, _("Done."))
        return redirect(reverse_lazy("admin:myapp_mymodel_change", args=[object_id]))

    return render(request, "myapp/action_form.html", {
        "form": form,
        "object": obj,
        "title": _("Custom Action"),
        **self.admin_site.each_context(request),
    })
```

### Hide Default Actions

```python
class MyAdmin(ModelAdmin):
    actions_list_hide_default = True    # hide "Delete selected" etc.
    actions_detail_hide_default = True
```

### Custom URLs

Register custom URL patterns via `get_urls()`:

```python
def get_urls(self):
    return super().get_urls() + [
        path("custom-page/", self.admin_site.admin_view(CustomView.as_view(model_admin=self)), name="custom_page"),
    ]
```

## Display Decorator

### Imports

```python
from unfold.decorators import display
```

### @display Parameters

| Parameter | Type | Description |
|-----------|------|-------------|
| `description` | str | Column header text |
| `ordering` | str | Enable sorting via this field |
| `boolean` | bool | Render as check/cross icon |
| `label` | bool/dict | Colored label badge |
| `header` | bool | Rich header with avatar/initials |
| `dropdown` | bool | Interactive dropdown menu |
| `image` | bool | Render as image thumbnail |

### Label Colors

Map field values to color schemes:

```python
@display(description=_("Status"), ordering="status", label={
    "active": "success",      # green
    "pending": "info",        # blue
    "suspended": "warning",   # orange
    "banned": "danger",       # red
})
def show_status(self, obj):
    return obj.status
```

For generic styling without color mapping:

```python
@display(description=_("Code"), label=True)
def show_code(self, obj):
    return obj.code
```

### Header Display

Returns a list: `[primary_text, secondary_text, badge_text, image_config]`

```python
@display(description=_("Employee"), header=True)
def show_employee(self, obj):
    return [
        obj.full_name,                    # line 1 (bold)
        obj.department,                   # line 2 (muted)
        obj.initials,                     # circular badge
        {
            "path": obj.photo.url if obj.photo else None,
            "squared": False,             # circular crop (default)
            "borderless": True,
            "width": 24,
            "height": 24,
        },
    ]
```

Any element can be `None` to skip it.

### Dropdown Display

Returns a dict with items or custom HTML:

```python
# List-based dropdown
@display(description=_("Roles"), dropdown=True)
def show_roles(self, obj):
    roles = obj.roles.all()
    if not roles:
        return "-"

    return {
        "title": f"{roles.count()} roles",
        "striped": True,               # alternating row colors
        "height": 400,                 # fixed height
        "max_height": 200,             # max before scrolling
        "width": 240,                  # custom width
        "items": [
            {"title": role.name, "link": role.get_admin_url()}
            for role in roles
        ],
    }

# Custom HTML dropdown
@display(description=_("Preview"), dropdown=True)
def show_preview(self, obj):
    return {
        "title": "Preview",
        "content": render_to_string("myapp/preview_dropdown.html", {"obj": obj}),
    }
```

### Boolean Display

```python
@display(description=_("Active"), boolean=True)
def show_active(self, obj):
    return obj.is_active
```

## Filter Classes

### Installation

```python
INSTALLED_APPS = [
    "unfold",
    "unfold.contrib.filters",  # must follow unfold
    # ...
]
```

### Important: `list_filter_submit`

Input-based filters (text, numeric, date) require a submit button:

```python
class MyAdmin(ModelAdmin):
    list_filter_submit = True   # adds submit button to filter panel
    list_filter_sheet = False   # True = filters in sliding sheet panel
```

### Available Filter Classes

All from `unfold.contrib.filters.admin`:

| Filter Class | Input Type | Use Case |
|-------------|------------|----------|
| `TextFilter` | Text input | Custom text search (abstract - subclass it) |
| `RangeNumericFilter` | Two number inputs | Numeric range (min-max) |
| `SingleNumericFilter` | One number input | Single numeric value (__gte) |
| `SliderNumericFilter` | Slider control | Numeric range with slider |
| `RangeNumericListFilter` | Two number inputs | Numeric range (not tied to model field) |
| `RangeDateFilter` | Two date pickers | Date range |
| `RangeDateTimeFilter` | Two datetime pickers | DateTime range |
| `DropdownFilter` | Select dropdown | Custom dropdown (abstract - subclass it) |
| `MultipleDropdownFilter` | Multi-select dropdown | Custom multi-select dropdown (abstract) |
| `ChoicesDropdownFilter` | Select dropdown | CharField with choices |
| `MultipleChoicesDropdownFilter` | Multi-select dropdown | CharField choices multi-select |
| `RelatedDropdownFilter` | Select dropdown | ForeignKey selection |
| `MultipleRelatedDropdownFilter` | Multi-select dropdown | ForeignKey multi-select |
| `RelatedCheckboxFilter` | Checkbox group | ForeignKey as checkboxes |
| `ChoicesCheckboxFilter` | Checkbox group | CharField choices as checkboxes |
| `AllValuesCheckboxFilter` | Checkbox group | All distinct field values |
| `RadioFilter` | Radio buttons | Custom radio (abstract - subclass it) |
| `BooleanRadioFilter` | Radio buttons | Boolean field |
| `ChoicesRadioFilter` | Radio buttons | CharField choices as radios |
| `CheckboxFilter` | Checkbox group | Custom choices (abstract - subclass it) |
| `AutocompleteSelectFilter` | Autocomplete single | Related model single search |
| `AutocompleteSelectMultipleFilter` | Autocomplete multi-select | Related model multi search |
| `FieldTextFilter` | Text input | Field-based text filter (__icontains) |

### Usage Patterns

```python
from unfold.contrib.filters.admin import (
    TextFilter, RangeNumericFilter, RangeDateFilter, RangeDateTimeFilter,
    SingleNumericFilter, SliderNumericFilter, RangeNumericListFilter,
    DropdownFilter, MultipleDropdownFilter,
    ChoicesDropdownFilter, MultipleChoicesDropdownFilter,
    RelatedDropdownFilter, MultipleRelatedDropdownFilter,
    RelatedCheckboxFilter, ChoicesCheckboxFilter, AllValuesCheckboxFilter,
    BooleanRadioFilter, CheckboxFilter, AutocompleteSelectMultipleFilter,
)

class MyAdmin(ModelAdmin):
    list_filter_submit = True
    list_filter = [
        # Tuple syntax: (field_name, FilterClass)
        ("price", RangeNumericFilter),
        ("status", ChoicesDropdownFilter),       # dropdown for choices
        ("status", ChoicesCheckboxFilter),        # or checkboxes
        ("created_at", RangeDateFilter),
        ("category", RelatedDropdownFilter),
        ("category", MultipleRelatedDropdownFilter),  # multi-select variant
        ("is_active", BooleanRadioFilter),
        ("tags", AutocompleteSelectMultipleFilter),
        ("rating", SingleNumericFilter),

        # Direct class (for custom filters)
        NameSearchFilter,
    ]
```

### Slider Filter with Decimals

```python
class PriceSliderFilter(SliderNumericFilter):
    MAX_DECIMALS = 2
    STEP = 0.01
```

## Custom Filters

### Custom Dropdown Filter

Subclass `DropdownFilter` and implement `lookups()` and `queryset()`:

```python
from unfold.contrib.filters.admin import DropdownFilter

class RegionFilter(DropdownFilter):
    title = _("Region")
    parameter_name = "region"

    def lookups(self, request, model_admin):
        return [
            ["north", _("North")],
            ["south", _("South")],
            ["east", _("East")],
            ["west", _("West")],
        ]

    def queryset(self, request, queryset):
        if self.value() not in EMPTY_VALUES:
            return queryset.filter(region=self.value())
        return queryset
```

### Custom Text Filter

Subclass `TextFilter` and implement `queryset()`:

```python
from django.core.validators import EMPTY_VALUES
from unfold.contrib.filters.admin import TextFilter

class FullNameFilter(TextFilter):
    title = _("Full name")
    parameter_name = "fullname"

    def queryset(self, request, queryset):
        if self.value() in EMPTY_VALUES:
            return queryset
        return queryset.filter(
            Q(first_name__icontains=self.value()) |
            Q(last_name__icontains=self.value())
        )
```

### Custom Checkbox Filter

Subclass `CheckboxFilter` and implement `lookups()` and `queryset()`:

```python
from unfold.contrib.filters.admin import CheckboxFilter

class StatusCheckboxFilter(CheckboxFilter):
    title = _("Status")
    parameter_name = "custom_status"

    def lookups(self, request, model_admin):
        return [("active", _("Active")), ("inactive", _("Inactive"))]

    def queryset(self, request, queryset):
        if self.value() not in EMPTY_VALUES:
            return queryset.filter(status__in=self.value())
        return queryset
```
