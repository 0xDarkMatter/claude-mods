# Tailwind Component Patterns

Complete, accessible component patterns with Tailwind CSS. All examples include dark mode support and accessibility attributes.

## Cards

### Basic Card

```html
<div class="bg-white dark:bg-gray-800 rounded-lg shadow-md p-6">
  <h3 class="text-lg font-semibold text-gray-900 dark:text-white mb-2">Card Title</h3>
  <p class="text-gray-600 dark:text-gray-400">Card content goes here with a reasonable amount of text.</p>
</div>
```

### Card with Image

```html
<div class="bg-white dark:bg-gray-800 rounded-lg shadow-md overflow-hidden">
  <img src="image.jpg" alt="Description of image" class="w-full h-48 object-cover">
  <div class="p-6">
    <h3 class="text-lg font-semibold text-gray-900 dark:text-white mb-2">Card Title</h3>
    <p class="text-gray-600 dark:text-gray-400 mb-4">Supporting text for this card.</p>
    <a href="#" class="text-blue-600 dark:text-blue-400 hover:underline font-medium">Read more &rarr;</a>
  </div>
</div>
```

### Horizontal Card

```html
<div class="flex flex-col sm:flex-row bg-white dark:bg-gray-800 rounded-lg shadow-md overflow-hidden">
  <img src="image.jpg" alt="Description" class="w-full sm:w-48 h-48 sm:h-auto object-cover">
  <div class="p-6 flex flex-col justify-center">
    <h3 class="text-lg font-semibold text-gray-900 dark:text-white mb-2">Horizontal Card</h3>
    <p class="text-gray-600 dark:text-gray-400">Image sits beside the content on larger screens, stacks on mobile.</p>
  </div>
</div>
```

### Interactive Card (Clickable)

```html
<a href="#" class="block bg-white dark:bg-gray-800 rounded-lg shadow-md p-6
                   hover:shadow-lg hover:ring-2 hover:ring-blue-500/20
                   focus-visible:outline-2 focus-visible:outline-blue-600
                   transition-all duration-200">
  <h3 class="text-lg font-semibold text-gray-900 dark:text-white mb-2">Clickable Card</h3>
  <p class="text-gray-600 dark:text-gray-400">The entire card is a link with hover and focus states.</p>
</a>
```

### Pricing Card

```html
<div class="bg-white dark:bg-gray-800 rounded-2xl shadow-xl p-8 border-2 border-blue-500 relative">
  <div class="absolute -top-4 left-1/2 -translate-x-1/2 bg-blue-500 text-white px-4 py-1 rounded-full text-sm font-medium">
    Most Popular
  </div>
  <h3 class="text-xl font-bold text-gray-900 dark:text-white">Pro Plan</h3>
  <div class="mt-4">
    <span class="text-4xl font-bold text-gray-900 dark:text-white">$29</span>
    <span class="text-gray-500 dark:text-gray-400">/month</span>
  </div>
  <ul class="mt-6 space-y-3" role="list">
    <li class="flex items-center text-gray-600 dark:text-gray-400">
      <svg class="w-5 h-5 text-green-500 mr-3 shrink-0" fill="none" stroke="currentColor" viewBox="0 0 24 24" aria-hidden="true">
        <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M5 13l4 4L19 7"/>
      </svg>
      Unlimited projects
    </li>
    <li class="flex items-center text-gray-600 dark:text-gray-400">
      <svg class="w-5 h-5 text-green-500 mr-3 shrink-0" fill="none" stroke="currentColor" viewBox="0 0 24 24" aria-hidden="true">
        <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M5 13l4 4L19 7"/>
      </svg>
      Advanced analytics
    </li>
    <li class="flex items-center text-gray-600 dark:text-gray-400">
      <svg class="w-5 h-5 text-green-500 mr-3 shrink-0" fill="none" stroke="currentColor" viewBox="0 0 24 24" aria-hidden="true">
        <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M5 13l4 4L19 7"/>
      </svg>
      Priority support
    </li>
  </ul>
  <button class="w-full mt-8 bg-blue-600 text-white py-3 rounded-lg font-medium hover:bg-blue-700 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-blue-600 transition-colors">
    Get Started
  </button>
</div>
```

### Feature Card

```html
<div class="bg-white dark:bg-gray-800 rounded-xl shadow-lg p-6 hover:shadow-xl transition-shadow">
  <div class="w-12 h-12 bg-blue-100 dark:bg-blue-900/30 rounded-lg flex items-center justify-center mb-4">
    <svg class="w-6 h-6 text-blue-600 dark:text-blue-400" fill="none" stroke="currentColor" viewBox="0 0 24 24" aria-hidden="true">
      <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M13 10V3L4 14h7v7l9-11h-7z"/>
    </svg>
  </div>
  <h3 class="text-lg font-semibold text-gray-900 dark:text-white mb-2">Feature Name</h3>
  <p class="text-gray-600 dark:text-gray-400">Description of this feature and its value to users.</p>
</div>
```

## Buttons

### Primary Button

```html
<button class="bg-blue-600 text-white px-4 py-2 rounded-lg font-medium
               hover:bg-blue-700 active:bg-blue-800
               focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-blue-600
               transition-colors">
  Primary Action
</button>
```

### Secondary Button

```html
<button class="bg-gray-200 dark:bg-gray-700 text-gray-800 dark:text-gray-200 px-4 py-2 rounded-lg font-medium
               hover:bg-gray-300 dark:hover:bg-gray-600 active:bg-gray-400
               focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-gray-500
               transition-colors">
  Secondary Action
</button>
```

### Outline Button

```html
<button class="border border-gray-300 dark:border-gray-600 text-gray-700 dark:text-gray-300 px-4 py-2 rounded-lg font-medium
               hover:bg-gray-50 dark:hover:bg-gray-800 active:bg-gray-100
               focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-gray-500
               transition-colors">
  Outline Action
</button>
```

### Ghost Button

```html
<button class="text-blue-600 dark:text-blue-400 px-4 py-2 rounded-lg font-medium
               hover:bg-blue-50 dark:hover:bg-blue-900/20 active:bg-blue-100
               focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-blue-600
               transition-colors">
  Ghost Action
</button>
```

### Icon Button

```html
<button class="p-2 rounded-lg text-gray-500 dark:text-gray-400
               hover:bg-gray-100 dark:hover:bg-gray-800 hover:text-gray-700 dark:hover:text-gray-200
               focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-gray-500
               transition-colors"
        aria-label="Close">
  <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24" aria-hidden="true">
    <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M6 18L18 6M6 6l12 12"/>
  </svg>
</button>
```

### Loading Button

```html
<button class="inline-flex items-center px-4 py-2 bg-blue-600 text-white rounded-lg font-medium
               disabled:opacity-60 disabled:cursor-not-allowed transition-colors" disabled>
  <svg class="animate-spin -ml-1 mr-2 h-4 w-4" fill="none" viewBox="0 0 24 24" aria-hidden="true">
    <circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4"/>
    <path class="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4z"/>
  </svg>
  Processing...
</button>
```

### Button Group

```html
<div class="inline-flex rounded-lg shadow-sm" role="group">
  <button class="px-4 py-2 text-sm font-medium text-gray-700 dark:text-gray-300 bg-white dark:bg-gray-800
                 border border-gray-300 dark:border-gray-600 rounded-l-lg
                 hover:bg-gray-50 dark:hover:bg-gray-700 focus:z-10 focus-visible:outline-2 focus-visible:outline-blue-600">
    Left
  </button>
  <button class="px-4 py-2 text-sm font-medium text-gray-700 dark:text-gray-300 bg-white dark:bg-gray-800
                 border-t border-b border-gray-300 dark:border-gray-600
                 hover:bg-gray-50 dark:hover:bg-gray-700 focus:z-10 focus-visible:outline-2 focus-visible:outline-blue-600">
    Center
  </button>
  <button class="px-4 py-2 text-sm font-medium text-gray-700 dark:text-gray-300 bg-white dark:bg-gray-800
                 border border-gray-300 dark:border-gray-600 rounded-r-lg
                 hover:bg-gray-50 dark:hover:bg-gray-700 focus:z-10 focus-visible:outline-2 focus-visible:outline-blue-600">
    Right
  </button>
</div>
```

### Button Sizes

```html
<!-- Small -->
<button class="bg-blue-600 text-white px-3 py-1.5 text-sm rounded-md font-medium hover:bg-blue-700 transition-colors">Small</button>
<!-- Medium (default) -->
<button class="bg-blue-600 text-white px-4 py-2 text-base rounded-lg font-medium hover:bg-blue-700 transition-colors">Medium</button>
<!-- Large -->
<button class="bg-blue-600 text-white px-6 py-3 text-lg rounded-lg font-medium hover:bg-blue-700 transition-colors">Large</button>
```

## Forms

### Text Input

```html
<div>
  <label for="name" class="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">Full Name</label>
  <input type="text" id="name"
    class="w-full px-3 py-2 bg-white dark:bg-gray-800 border border-gray-300 dark:border-gray-600
           text-gray-900 dark:text-gray-100 rounded-lg
           placeholder:text-gray-400 dark:placeholder:text-gray-500
           focus:ring-2 focus:ring-blue-500 focus:border-transparent
           disabled:bg-gray-100 dark:disabled:bg-gray-900 disabled:cursor-not-allowed"
    placeholder="John Doe">
</div>
```

### Textarea

```html
<div>
  <label for="message" class="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">Message</label>
  <textarea id="message" rows="4"
    class="w-full px-3 py-2 bg-white dark:bg-gray-800 border border-gray-300 dark:border-gray-600
           text-gray-900 dark:text-gray-100 rounded-lg resize-y
           placeholder:text-gray-400 dark:placeholder:text-gray-500
           focus:ring-2 focus:ring-blue-500 focus:border-transparent"
    placeholder="Write your message..."></textarea>
  <p class="mt-1 text-sm text-gray-500 dark:text-gray-400">Max 500 characters.</p>
</div>
```

### Select

```html
<div>
  <label for="country" class="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">Country</label>
  <select id="country"
    class="w-full px-3 py-2 bg-white dark:bg-gray-800 border border-gray-300 dark:border-gray-600
           text-gray-900 dark:text-gray-100 rounded-lg
           focus:ring-2 focus:ring-blue-500 focus:border-transparent">
    <option value="">Select a country</option>
    <option value="us">United States</option>
    <option value="uk">United Kingdom</option>
    <option value="ca">Canada</option>
  </select>
</div>
```

### Checkbox

```html
<div class="flex items-start">
  <input type="checkbox" id="terms"
    class="mt-1 h-4 w-4 rounded border-gray-300 dark:border-gray-600
           text-blue-600 focus:ring-blue-500 dark:bg-gray-800">
  <label for="terms" class="ml-2 text-sm text-gray-700 dark:text-gray-300">
    I agree to the <a href="#" class="text-blue-600 dark:text-blue-400 hover:underline">terms and conditions</a>
  </label>
</div>
```

### Radio Group

```html
<fieldset>
  <legend class="text-sm font-medium text-gray-700 dark:text-gray-300 mb-2">Notification preference</legend>
  <div class="space-y-2">
    <label class="flex items-center">
      <input type="radio" name="notification" value="email"
        class="h-4 w-4 border-gray-300 dark:border-gray-600 text-blue-600 focus:ring-blue-500 dark:bg-gray-800">
      <span class="ml-2 text-sm text-gray-700 dark:text-gray-300">Email</span>
    </label>
    <label class="flex items-center">
      <input type="radio" name="notification" value="sms"
        class="h-4 w-4 border-gray-300 dark:border-gray-600 text-blue-600 focus:ring-blue-500 dark:bg-gray-800">
      <span class="ml-2 text-sm text-gray-700 dark:text-gray-300">SMS</span>
    </label>
    <label class="flex items-center">
      <input type="radio" name="notification" value="push"
        class="h-4 w-4 border-gray-300 dark:border-gray-600 text-blue-600 focus:ring-blue-500 dark:bg-gray-800">
      <span class="ml-2 text-sm text-gray-700 dark:text-gray-300">Push notification</span>
    </label>
  </div>
</fieldset>
```

### Toggle Switch

```html
<label class="relative inline-flex items-center cursor-pointer">
  <input type="checkbox" class="sr-only peer">
  <div class="w-11 h-6 bg-gray-200 dark:bg-gray-700 rounded-full
              peer-checked:bg-blue-600 peer-focus-visible:ring-2 peer-focus-visible:ring-blue-500
              after:content-[''] after:absolute after:top-0.5 after:left-[2px]
              after:bg-white after:rounded-full after:h-5 after:w-5
              after:transition-all peer-checked:after:translate-x-full"></div>
  <span class="ml-3 text-sm text-gray-700 dark:text-gray-300">Enable notifications</span>
</label>
```

### File Upload

```html
<div>
  <label for="file-upload" class="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">Upload file</label>
  <div class="flex items-center justify-center w-full">
    <label for="file-upload"
      class="flex flex-col items-center justify-center w-full h-32
             border-2 border-dashed border-gray-300 dark:border-gray-600
             rounded-lg cursor-pointer
             hover:border-blue-500 hover:bg-blue-50 dark:hover:bg-blue-900/10
             transition-colors">
      <svg class="w-8 h-8 text-gray-400 mb-2" fill="none" stroke="currentColor" viewBox="0 0 24 24" aria-hidden="true">
        <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2"
              d="M7 16a4 4 0 01-.88-7.903A5 5 0 1115.9 6L16 6a5 5 0 011 9.9M15 13l-3-3m0 0l-3 3m3-3v12"/>
      </svg>
      <p class="text-sm text-gray-500 dark:text-gray-400"><span class="font-medium text-blue-600 dark:text-blue-400">Click to upload</span> or drag and drop</p>
      <p class="text-xs text-gray-400 dark:text-gray-500 mt-1">PNG, JPG, PDF up to 10MB</p>
      <input type="file" id="file-upload" class="hidden">
    </label>
  </div>
</div>
```

### Search Input

```html
<div class="relative">
  <div class="absolute inset-y-0 left-0 flex items-center pl-3 pointer-events-none">
    <svg class="w-5 h-5 text-gray-400" fill="none" stroke="currentColor" viewBox="0 0 24 24" aria-hidden="true">
      <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M21 21l-6-6m2-5a7 7 0 11-14 0 7 7 0 0114 0z"/>
    </svg>
  </div>
  <input type="search"
    class="w-full pl-10 pr-4 py-2 bg-white dark:bg-gray-800 border border-gray-300 dark:border-gray-600
           text-gray-900 dark:text-gray-100 rounded-lg
           placeholder:text-gray-400 dark:placeholder:text-gray-500
           focus:ring-2 focus:ring-blue-500 focus:border-transparent"
    placeholder="Search...">
</div>
```

### Input with Icon (Addon)

```html
<div>
  <label for="website" class="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">Website</label>
  <div class="flex">
    <span class="inline-flex items-center px-3 rounded-l-lg border border-r-0 border-gray-300 dark:border-gray-600
                 bg-gray-50 dark:bg-gray-700 text-gray-500 dark:text-gray-400 text-sm">
      https://
    </span>
    <input type="text" id="website"
      class="flex-1 px-3 py-2 bg-white dark:bg-gray-800 border border-gray-300 dark:border-gray-600
             text-gray-900 dark:text-gray-100 rounded-r-lg
             focus:ring-2 focus:ring-blue-500 focus:border-transparent"
      placeholder="example.com">
  </div>
</div>
```

### Input Group (Button Addon)

```html
<div class="flex">
  <input type="email"
    class="flex-1 px-4 py-2 bg-white dark:bg-gray-800 border border-gray-300 dark:border-gray-600
           text-gray-900 dark:text-gray-100 rounded-l-lg
           focus:ring-2 focus:ring-blue-500 focus:border-transparent"
    placeholder="you@example.com">
  <button class="px-6 py-2 bg-blue-600 text-white rounded-r-lg font-medium
                 hover:bg-blue-700 focus-visible:outline-2 focus-visible:outline-blue-600
                 transition-colors">
    Subscribe
  </button>
</div>
```

### Validation States

```html
<!-- Error state -->
<div>
  <label for="email-err" class="block text-sm font-medium text-red-700 dark:text-red-400 mb-1">Email</label>
  <input type="email" id="email-err"
    class="w-full px-3 py-2 bg-white dark:bg-gray-800
           border border-red-500 text-gray-900 dark:text-gray-100 rounded-lg
           focus:ring-2 focus:ring-red-500 focus:border-transparent"
    value="invalid-email" aria-describedby="email-error" aria-invalid="true">
  <p id="email-error" class="mt-1 text-sm text-red-600 dark:text-red-400" role="alert">
    Please enter a valid email address.
  </p>
</div>

<!-- Success state -->
<div>
  <label for="email-ok" class="block text-sm font-medium text-green-700 dark:text-green-400 mb-1">Email</label>
  <input type="email" id="email-ok"
    class="w-full px-3 py-2 bg-white dark:bg-gray-800
           border border-green-500 text-gray-900 dark:text-gray-100 rounded-lg
           focus:ring-2 focus:ring-green-500 focus:border-transparent"
    value="user@example.com" aria-describedby="email-success">
  <p id="email-success" class="mt-1 text-sm text-green-600 dark:text-green-400">
    Email address is valid.
  </p>
</div>
```

## Navigation

### Horizontal Navbar

```html
<nav class="bg-white dark:bg-gray-900 shadow" aria-label="Main navigation">
  <div class="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8">
    <div class="flex items-center justify-between h-16">
      <a href="/" class="text-xl font-bold text-gray-900 dark:text-white">Brand</a>
      <div class="hidden md:flex items-center gap-6">
        <a href="#" class="text-gray-600 dark:text-gray-300 hover:text-gray-900 dark:hover:text-white transition-colors">Home</a>
        <a href="#" class="text-gray-600 dark:text-gray-300 hover:text-gray-900 dark:hover:text-white transition-colors">Features</a>
        <a href="#" class="text-gray-600 dark:text-gray-300 hover:text-gray-900 dark:hover:text-white transition-colors">Pricing</a>
        <a href="#" class="bg-blue-600 text-white px-4 py-2 rounded-lg hover:bg-blue-700 transition-colors">Get Started</a>
      </div>
      <!-- Mobile menu button -->
      <button class="md:hidden p-2 rounded-lg text-gray-500 hover:bg-gray-100 dark:hover:bg-gray-800"
              aria-label="Toggle menu" aria-expanded="false">
        <svg class="w-6 h-6" fill="none" stroke="currentColor" viewBox="0 0 24 24" aria-hidden="true">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M4 6h16M4 12h16M4 18h16"/>
        </svg>
      </button>
    </div>
  </div>
</nav>
```

### Mobile Hamburger Menu (Expanded State)

```html
<!-- Mobile menu panel (toggle with JS) -->
<div class="md:hidden bg-white dark:bg-gray-900 border-t border-gray-200 dark:border-gray-700">
  <div class="px-4 py-3 space-y-1">
    <a href="#" class="block px-3 py-2 rounded-lg text-gray-900 dark:text-white bg-gray-100 dark:bg-gray-800 font-medium">Home</a>
    <a href="#" class="block px-3 py-2 rounded-lg text-gray-600 dark:text-gray-300 hover:bg-gray-50 dark:hover:bg-gray-800">Features</a>
    <a href="#" class="block px-3 py-2 rounded-lg text-gray-600 dark:text-gray-300 hover:bg-gray-50 dark:hover:bg-gray-800">Pricing</a>
  </div>
  <div class="px-4 py-3 border-t border-gray-200 dark:border-gray-700">
    <a href="#" class="block w-full text-center bg-blue-600 text-white px-4 py-2 rounded-lg hover:bg-blue-700">Get Started</a>
  </div>
</div>
```

### Sidebar Navigation

```html
<aside class="w-64 bg-gray-900 text-white min-h-screen flex flex-col" aria-label="Sidebar navigation">
  <div class="p-4 border-b border-gray-800">
    <h2 class="text-lg font-semibold">Dashboard</h2>
  </div>
  <nav class="flex-1 p-4 space-y-1">
    <a href="#" class="flex items-center gap-3 px-3 py-2 bg-gray-800 rounded-lg text-white font-medium"
       aria-current="page">
      <svg class="w-5 h-5 shrink-0" fill="none" stroke="currentColor" viewBox="0 0 24 24" aria-hidden="true">
        <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M3 12l2-2m0 0l7-7 7 7M5 10v10a1 1 0 001 1h3m10-11l2 2m-2-2v10a1 1 0 01-1 1h-3m-6 0a1 1 0 001-1v-4a1 1 0 011-1h2a1 1 0 011 1v4a1 1 0 001 1m-6 0h6"/>
      </svg>
      Home
    </a>
    <a href="#" class="flex items-center gap-3 px-3 py-2 text-gray-400 hover:bg-gray-800 hover:text-white rounded-lg transition-colors">
      <svg class="w-5 h-5 shrink-0" fill="none" stroke="currentColor" viewBox="0 0 24 24" aria-hidden="true">
        <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 4.354a4 4 0 110 5.292M15 21H3v-1a6 6 0 0112 0v1zm0 0h6v-1a6 6 0 00-9-5.197M13 7a4 4 0 11-8 0 4 4 0 018 0z"/>
      </svg>
      Users
    </a>
    <a href="#" class="flex items-center gap-3 px-3 py-2 text-gray-400 hover:bg-gray-800 hover:text-white rounded-lg transition-colors">
      <svg class="w-5 h-5 shrink-0" fill="none" stroke="currentColor" viewBox="0 0 24 24" aria-hidden="true">
        <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M10.325 4.317c.426-1.756 2.924-1.756 3.35 0a1.724 1.724 0 002.573 1.066c1.543-.94 3.31.826 2.37 2.37a1.724 1.724 0 001.066 2.573c1.756.426 1.756 2.924 0 3.35a1.724 1.724 0 00-1.066 2.573c.94 1.543-.826 3.31-2.37 2.37a1.724 1.724 0 00-2.573 1.066c-.426 1.756-2.924 1.756-3.35 0a1.724 1.724 0 00-2.573-1.066c-1.543.94-3.31-.826-2.37-2.37a1.724 1.724 0 00-1.066-2.573c-1.756-.426-1.756-2.924 0-3.35a1.724 1.724 0 001.066-2.573c-.94-1.543.826-3.31 2.37-2.37.996.608 2.296.07 2.572-1.065z"/>
        <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M15 12a3 3 0 11-6 0 3 3 0 016 0z"/>
      </svg>
      Settings
    </a>
  </nav>
</aside>
```

### Breadcrumbs

```html
<nav aria-label="Breadcrumb">
  <ol class="flex items-center gap-2 text-sm">
    <li><a href="#" class="text-gray-500 dark:text-gray-400 hover:text-gray-700 dark:hover:text-gray-200">Home</a></li>
    <li class="text-gray-400 dark:text-gray-500" aria-hidden="true">/</li>
    <li><a href="#" class="text-gray-500 dark:text-gray-400 hover:text-gray-700 dark:hover:text-gray-200">Products</a></li>
    <li class="text-gray-400 dark:text-gray-500" aria-hidden="true">/</li>
    <li class="text-gray-900 dark:text-white font-medium" aria-current="page">Widget Pro</li>
  </ol>
</nav>
```

### Tabs

```html
<div>
  <div class="border-b border-gray-200 dark:border-gray-700" role="tablist">
    <nav class="flex gap-0 -mb-px">
      <button role="tab" aria-selected="true"
        class="px-4 py-3 text-sm font-medium text-blue-600 dark:text-blue-400 border-b-2 border-blue-600 dark:border-blue-400">
        General
      </button>
      <button role="tab" aria-selected="false"
        class="px-4 py-3 text-sm font-medium text-gray-500 dark:text-gray-400 border-b-2 border-transparent
               hover:text-gray-700 dark:hover:text-gray-200 hover:border-gray-300">
        Security
      </button>
      <button role="tab" aria-selected="false"
        class="px-4 py-3 text-sm font-medium text-gray-500 dark:text-gray-400 border-b-2 border-transparent
               hover:text-gray-700 dark:hover:text-gray-200 hover:border-gray-300">
        Billing
      </button>
    </nav>
  </div>
  <div role="tabpanel" class="p-4">
    Tab content goes here.
  </div>
</div>
```

### Pagination

```html
<nav aria-label="Pagination">
  <ul class="inline-flex items-center gap-1">
    <li>
      <a href="#" class="px-3 py-2 rounded-lg text-gray-500 dark:text-gray-400 hover:bg-gray-100 dark:hover:bg-gray-800" aria-label="Previous page">
        &laquo;
      </a>
    </li>
    <li><a href="#" class="px-3 py-2 rounded-lg text-gray-700 dark:text-gray-300 hover:bg-gray-100 dark:hover:bg-gray-800">1</a></li>
    <li><a href="#" class="px-3 py-2 rounded-lg bg-blue-600 text-white font-medium" aria-current="page">2</a></li>
    <li><a href="#" class="px-3 py-2 rounded-lg text-gray-700 dark:text-gray-300 hover:bg-gray-100 dark:hover:bg-gray-800">3</a></li>
    <li><span class="px-3 py-2 text-gray-400">...</span></li>
    <li><a href="#" class="px-3 py-2 rounded-lg text-gray-700 dark:text-gray-300 hover:bg-gray-100 dark:hover:bg-gray-800">12</a></li>
    <li>
      <a href="#" class="px-3 py-2 rounded-lg text-gray-500 dark:text-gray-400 hover:bg-gray-100 dark:hover:bg-gray-800" aria-label="Next page">
        &raquo;
      </a>
    </li>
  </ul>
</nav>
```

## Modals

### Centered Modal with Overlay

```html
<div class="fixed inset-0 z-50 flex items-center justify-center" role="dialog" aria-modal="true" aria-labelledby="modal-title">
  <!-- Backdrop -->
  <div class="fixed inset-0 bg-black/50 transition-opacity" aria-hidden="true"></div>
  <!-- Panel -->
  <div class="relative bg-white dark:bg-gray-800 rounded-xl shadow-xl w-full max-w-lg mx-4 p-6">
    <div class="flex items-center justify-between mb-4">
      <h2 id="modal-title" class="text-lg font-semibold text-gray-900 dark:text-white">Edit Profile</h2>
      <button class="p-1 rounded-lg text-gray-400 hover:text-gray-600 dark:hover:text-gray-200 hover:bg-gray-100 dark:hover:bg-gray-700"
              aria-label="Close modal">
        <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24" aria-hidden="true">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M6 18L18 6M6 6l12 12"/>
        </svg>
      </button>
    </div>
    <div class="mb-6">
      <p class="text-gray-600 dark:text-gray-400">Modal body content goes here.</p>
    </div>
    <div class="flex justify-end gap-3">
      <button class="px-4 py-2 text-gray-700 dark:text-gray-300 hover:bg-gray-100 dark:hover:bg-gray-700 rounded-lg transition-colors">Cancel</button>
      <button class="px-4 py-2 bg-blue-600 text-white rounded-lg hover:bg-blue-700 transition-colors">Save Changes</button>
    </div>
  </div>
</div>
```

### Slide-Over Panel

```html
<div class="fixed inset-0 z-50 flex justify-end" role="dialog" aria-modal="true" aria-labelledby="slideover-title">
  <div class="fixed inset-0 bg-black/50" aria-hidden="true"></div>
  <div class="relative w-full max-w-md bg-white dark:bg-gray-800 shadow-xl flex flex-col h-full">
    <div class="flex items-center justify-between px-6 py-4 border-b border-gray-200 dark:border-gray-700">
      <h2 id="slideover-title" class="text-lg font-semibold text-gray-900 dark:text-white">Panel Title</h2>
      <button class="p-1 rounded-lg text-gray-400 hover:text-gray-600 dark:hover:text-gray-200" aria-label="Close panel">
        <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24" aria-hidden="true">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M6 18L18 6M6 6l12 12"/>
        </svg>
      </button>
    </div>
    <div class="flex-1 overflow-y-auto px-6 py-4">
      <p class="text-gray-600 dark:text-gray-400">Slide-over content with vertical scroll.</p>
    </div>
    <div class="px-6 py-4 border-t border-gray-200 dark:border-gray-700 flex justify-end gap-3">
      <button class="px-4 py-2 text-gray-700 dark:text-gray-300 hover:bg-gray-100 dark:hover:bg-gray-700 rounded-lg">Cancel</button>
      <button class="px-4 py-2 bg-blue-600 text-white rounded-lg hover:bg-blue-700">Apply</button>
    </div>
  </div>
</div>
```

### Confirmation Dialog

```html
<div class="fixed inset-0 z-50 flex items-center justify-center" role="alertdialog" aria-modal="true" aria-labelledby="confirm-title" aria-describedby="confirm-desc">
  <div class="fixed inset-0 bg-black/50" aria-hidden="true"></div>
  <div class="relative bg-white dark:bg-gray-800 rounded-xl shadow-xl w-full max-w-sm mx-4 p-6 text-center">
    <div class="w-12 h-12 bg-red-100 dark:bg-red-900/30 rounded-full flex items-center justify-center mx-auto mb-4">
      <svg class="w-6 h-6 text-red-600 dark:text-red-400" fill="none" stroke="currentColor" viewBox="0 0 24 24" aria-hidden="true">
        <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 9v2m0 4h.01m-6.938 4h13.856c1.54 0 2.502-1.667 1.732-2.5L13.732 4c-.77-.833-1.964-.833-2.732 0L4.082 16.5c-.77.833.192 2.5 1.732 2.5z"/>
      </svg>
    </div>
    <h2 id="confirm-title" class="text-lg font-semibold text-gray-900 dark:text-white mb-2">Delete Item?</h2>
    <p id="confirm-desc" class="text-gray-600 dark:text-gray-400 mb-6">This action cannot be undone. The item will be permanently removed.</p>
    <div class="flex gap-3 justify-center">
      <button class="px-4 py-2 text-gray-700 dark:text-gray-300 hover:bg-gray-100 dark:hover:bg-gray-700 rounded-lg transition-colors">Cancel</button>
      <button class="px-4 py-2 bg-red-600 text-white rounded-lg hover:bg-red-700 transition-colors">Delete</button>
    </div>
  </div>
</div>
```

## Tables

### Basic Table

```html
<div class="overflow-x-auto rounded-lg border border-gray-200 dark:border-gray-700">
  <table class="min-w-full divide-y divide-gray-200 dark:divide-gray-700">
    <thead class="bg-gray-50 dark:bg-gray-800">
      <tr>
        <th scope="col" class="px-6 py-3 text-left text-xs font-medium text-gray-500 dark:text-gray-400 uppercase tracking-wider">Name</th>
        <th scope="col" class="px-6 py-3 text-left text-xs font-medium text-gray-500 dark:text-gray-400 uppercase tracking-wider">Email</th>
        <th scope="col" class="px-6 py-3 text-left text-xs font-medium text-gray-500 dark:text-gray-400 uppercase tracking-wider">Role</th>
        <th scope="col" class="px-6 py-3 text-right text-xs font-medium text-gray-500 dark:text-gray-400 uppercase tracking-wider">Actions</th>
      </tr>
    </thead>
    <tbody class="bg-white dark:bg-gray-900 divide-y divide-gray-200 dark:divide-gray-700">
      <tr class="hover:bg-gray-50 dark:hover:bg-gray-800">
        <td class="px-6 py-4 whitespace-nowrap text-sm font-medium text-gray-900 dark:text-white">Jane Doe</td>
        <td class="px-6 py-4 whitespace-nowrap text-sm text-gray-500 dark:text-gray-400">jane@example.com</td>
        <td class="px-6 py-4 whitespace-nowrap">
          <span class="px-2 py-1 text-xs font-medium bg-green-100 dark:bg-green-900 text-green-800 dark:text-green-300 rounded-full">Admin</span>
        </td>
        <td class="px-6 py-4 whitespace-nowrap text-right text-sm">
          <button class="text-blue-600 dark:text-blue-400 hover:underline">Edit</button>
        </td>
      </tr>
    </tbody>
  </table>
</div>
```

### Striped Table

```html
<table class="min-w-full">
  <thead>
    <tr class="border-b border-gray-200 dark:border-gray-700">
      <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 dark:text-gray-400 uppercase">Product</th>
      <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 dark:text-gray-400 uppercase">Price</th>
      <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 dark:text-gray-400 uppercase">Stock</th>
    </tr>
  </thead>
  <tbody>
    <tr class="odd:bg-white even:bg-gray-50 dark:odd:bg-gray-900 dark:even:bg-gray-800">
      <td class="px-6 py-4 text-sm text-gray-900 dark:text-white">Widget A</td>
      <td class="px-6 py-4 text-sm text-gray-500 dark:text-gray-400">$9.99</td>
      <td class="px-6 py-4 text-sm text-gray-500 dark:text-gray-400">142</td>
    </tr>
    <tr class="odd:bg-white even:bg-gray-50 dark:odd:bg-gray-900 dark:even:bg-gray-800">
      <td class="px-6 py-4 text-sm text-gray-900 dark:text-white">Widget B</td>
      <td class="px-6 py-4 text-sm text-gray-500 dark:text-gray-400">$19.99</td>
      <td class="px-6 py-4 text-sm text-gray-500 dark:text-gray-400">85</td>
    </tr>
  </tbody>
</table>
```

### Sortable Table Header

```html
<th scope="col" class="px-6 py-3 text-left text-xs font-medium text-gray-500 dark:text-gray-400 uppercase tracking-wider">
  <button class="group inline-flex items-center gap-1 hover:text-gray-700 dark:hover:text-gray-200">
    Name
    <svg class="w-4 h-4 text-gray-400 group-hover:text-gray-600" fill="none" stroke="currentColor" viewBox="0 0 24 24" aria-hidden="true">
      <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M7 11l5-5m0 0l5 5m-5-5v12"/>
    </svg>
  </button>
</th>
```

### Responsive Table (Stacked on Mobile)

```html
<!-- Horizontal scroll approach -->
<div class="overflow-x-auto -mx-4 sm:mx-0">
  <div class="inline-block min-w-full align-middle">
    <table class="min-w-full"><!-- table content --></table>
  </div>
</div>

<!-- Stacked approach (card-like on mobile) -->
<div class="sm:hidden space-y-4">
  <div class="bg-white dark:bg-gray-800 rounded-lg shadow p-4 space-y-2">
    <div class="flex justify-between">
      <span class="text-xs font-medium text-gray-500 dark:text-gray-400 uppercase">Name</span>
      <span class="text-sm text-gray-900 dark:text-white font-medium">Jane Doe</span>
    </div>
    <div class="flex justify-between">
      <span class="text-xs font-medium text-gray-500 dark:text-gray-400 uppercase">Email</span>
      <span class="text-sm text-gray-500 dark:text-gray-400">jane@example.com</span>
    </div>
    <div class="flex justify-between">
      <span class="text-xs font-medium text-gray-500 dark:text-gray-400 uppercase">Role</span>
      <span class="px-2 py-1 text-xs bg-green-100 text-green-800 rounded-full">Admin</span>
    </div>
  </div>
</div>
<!-- Desktop table (hidden on mobile) -->
<div class="hidden sm:block">
  <table class="min-w-full"><!-- full table --></table>
</div>
```

## Alerts

### Info Alert

```html
<div class="flex items-start gap-3 p-4 rounded-lg bg-blue-50 dark:bg-blue-900/20 border border-blue-200 dark:border-blue-800" role="status">
  <svg class="w-5 h-5 text-blue-600 dark:text-blue-400 mt-0.5 shrink-0" fill="currentColor" viewBox="0 0 20 20" aria-hidden="true">
    <path fill-rule="evenodd" d="M18 10a8 8 0 11-16 0 8 8 0 0116 0zm-7-4a1 1 0 11-2 0 1 1 0 012 0zM9 9a1 1 0 000 2v3a1 1 0 001 1h1a1 1 0 100-2v-3a1 1 0 00-1-1H9z" clip-rule="evenodd"/>
  </svg>
  <p class="text-sm text-blue-800 dark:text-blue-300">A new version is available. Please update to continue.</p>
</div>
```

### Success Alert

```html
<div class="flex items-start gap-3 p-4 rounded-lg bg-green-50 dark:bg-green-900/20 border border-green-200 dark:border-green-800" role="status">
  <svg class="w-5 h-5 text-green-600 dark:text-green-400 mt-0.5 shrink-0" fill="currentColor" viewBox="0 0 20 20" aria-hidden="true">
    <path fill-rule="evenodd" d="M10 18a8 8 0 100-16 8 8 0 000 16zm3.707-9.293a1 1 0 00-1.414-1.414L9 10.586 7.707 9.293a1 1 0 00-1.414 1.414l2 2a1 1 0 001.414 0l4-4z" clip-rule="evenodd"/>
  </svg>
  <p class="text-sm text-green-800 dark:text-green-300">Changes saved successfully.</p>
</div>
```

### Warning Alert

```html
<div class="flex items-start gap-3 p-4 rounded-lg bg-yellow-50 dark:bg-yellow-900/20 border border-yellow-200 dark:border-yellow-800" role="alert">
  <svg class="w-5 h-5 text-yellow-600 dark:text-yellow-400 mt-0.5 shrink-0" fill="currentColor" viewBox="0 0 20 20" aria-hidden="true">
    <path fill-rule="evenodd" d="M8.257 3.099c.765-1.36 2.722-1.36 3.486 0l5.58 9.92c.75 1.334-.213 2.98-1.742 2.98H4.42c-1.53 0-2.493-1.646-1.743-2.98l5.58-9.92zM11 13a1 1 0 11-2 0 1 1 0 012 0zm-1-8a1 1 0 00-1 1v3a1 1 0 002 0V6a1 1 0 00-1-1z" clip-rule="evenodd"/>
  </svg>
  <p class="text-sm text-yellow-800 dark:text-yellow-300">Your trial expires in 3 days. Upgrade to keep access.</p>
</div>
```

### Error Alert

```html
<div class="flex items-start gap-3 p-4 rounded-lg bg-red-50 dark:bg-red-900/20 border border-red-200 dark:border-red-800" role="alert">
  <svg class="w-5 h-5 text-red-600 dark:text-red-400 mt-0.5 shrink-0" fill="currentColor" viewBox="0 0 20 20" aria-hidden="true">
    <path fill-rule="evenodd" d="M10 18a8 8 0 100-16 8 8 0 000 16zM8.707 7.293a1 1 0 00-1.414 1.414L8.586 10l-1.293 1.293a1 1 0 101.414 1.414L10 11.414l1.293 1.293a1 1 0 001.414-1.414L11.414 10l1.293-1.293a1 1 0 00-1.414-1.414L10 8.586 8.707 7.293z" clip-rule="evenodd"/>
  </svg>
  <p class="text-sm text-red-800 dark:text-red-300">Failed to save changes. Please try again.</p>
</div>
```

### Dismissible Alert

```html
<div class="flex items-start gap-3 p-4 rounded-lg bg-blue-50 dark:bg-blue-900/20 border border-blue-200 dark:border-blue-800" role="status">
  <svg class="w-5 h-5 text-blue-600 dark:text-blue-400 mt-0.5 shrink-0" fill="currentColor" viewBox="0 0 20 20" aria-hidden="true">
    <path fill-rule="evenodd" d="M18 10a8 8 0 11-16 0 8 8 0 0116 0zm-7-4a1 1 0 11-2 0 1 1 0 012 0zM9 9a1 1 0 000 2v3a1 1 0 001 1h1a1 1 0 100-2v-3a1 1 0 00-1-1H9z" clip-rule="evenodd"/>
  </svg>
  <p class="flex-1 text-sm text-blue-800 dark:text-blue-300">Tip: You can drag items to reorder them.</p>
  <button class="text-blue-600 dark:text-blue-400 hover:text-blue-800 dark:hover:text-blue-200 p-0.5" aria-label="Dismiss">
    <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24" aria-hidden="true">
      <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M6 18L18 6M6 6l12 12"/>
    </svg>
  </button>
</div>
```

## Badges

### Inline Badge

```html
<span class="inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium bg-blue-100 dark:bg-blue-900 text-blue-800 dark:text-blue-300">
  New
</span>
```

### Pill Badge

```html
<span class="inline-flex items-center px-3 py-1 rounded-full text-sm font-medium bg-gray-100 dark:bg-gray-700 text-gray-800 dark:text-gray-300">
  Default
</span>
<span class="inline-flex items-center px-3 py-1 rounded-full text-sm font-medium bg-green-100 dark:bg-green-900 text-green-800 dark:text-green-300">
  Active
</span>
<span class="inline-flex items-center px-3 py-1 rounded-full text-sm font-medium bg-red-100 dark:bg-red-900 text-red-800 dark:text-red-300">
  Removed
</span>
```

### Badge with Dot Indicator

```html
<span class="inline-flex items-center gap-1.5 px-2.5 py-0.5 rounded-full text-xs font-medium bg-green-100 dark:bg-green-900 text-green-800 dark:text-green-300">
  <span class="w-1.5 h-1.5 bg-green-500 rounded-full" aria-hidden="true"></span>
  Online
</span>
<span class="inline-flex items-center gap-1.5 px-2.5 py-0.5 rounded-full text-xs font-medium bg-yellow-100 dark:bg-yellow-900 text-yellow-800 dark:text-yellow-300">
  <span class="w-1.5 h-1.5 bg-yellow-500 rounded-full" aria-hidden="true"></span>
  Idle
</span>
<span class="inline-flex items-center gap-1.5 px-2.5 py-0.5 rounded-full text-xs font-medium bg-gray-100 dark:bg-gray-700 text-gray-600 dark:text-gray-400">
  <span class="w-1.5 h-1.5 bg-gray-400 rounded-full" aria-hidden="true"></span>
  Offline
</span>
```

### Notification Count Badge

```html
<div class="relative inline-block">
  <button class="p-2 text-gray-500 dark:text-gray-400 hover:text-gray-700 dark:hover:text-gray-200" aria-label="Notifications (3 unread)">
    <svg class="w-6 h-6" fill="none" stroke="currentColor" viewBox="0 0 24 24" aria-hidden="true">
      <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M15 17h5l-1.405-1.405A2.032 2.032 0 0118 14.158V11a6.002 6.002 0 00-4-5.659V5a2 2 0 10-4 0v.341C7.67 6.165 6 8.388 6 11v3.159c0 .538-.214 1.055-.595 1.436L4 17h5m6 0v1a3 3 0 11-6 0v-1m6 0H9"/>
    </svg>
  </button>
  <span class="absolute -top-1 -right-1 flex items-center justify-center w-5 h-5 text-xs font-bold text-white bg-red-500 rounded-full">
    3
  </span>
</div>
```

## Avatars

### Image Avatar

```html
<img src="user.jpg" alt="Jane Doe" class="w-10 h-10 rounded-full object-cover ring-2 ring-white dark:ring-gray-800">
```

### Initials Avatar

```html
<div class="w-10 h-10 rounded-full bg-blue-600 flex items-center justify-center">
  <span class="text-sm font-medium text-white">JD</span>
</div>
```

### Avatar Group (Stacked)

```html
<div class="flex -space-x-3">
  <img src="user1.jpg" alt="User 1" class="w-10 h-10 rounded-full border-2 border-white dark:border-gray-800 object-cover">
  <img src="user2.jpg" alt="User 2" class="w-10 h-10 rounded-full border-2 border-white dark:border-gray-800 object-cover">
  <img src="user3.jpg" alt="User 3" class="w-10 h-10 rounded-full border-2 border-white dark:border-gray-800 object-cover">
  <div class="w-10 h-10 rounded-full border-2 border-white dark:border-gray-800 bg-gray-200 dark:bg-gray-700 flex items-center justify-center">
    <span class="text-xs font-medium text-gray-600 dark:text-gray-400">+5</span>
  </div>
</div>
```

## Dropdowns

### Basic Dropdown

```html
<div class="relative inline-block text-left">
  <button class="inline-flex items-center gap-2 px-4 py-2 bg-white dark:bg-gray-800 border border-gray-300 dark:border-gray-600
                 rounded-lg text-sm font-medium text-gray-700 dark:text-gray-300
                 hover:bg-gray-50 dark:hover:bg-gray-700 focus-visible:outline-2 focus-visible:outline-blue-600"
          aria-expanded="true" aria-haspopup="true">
    Options
    <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24" aria-hidden="true">
      <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M19 9l-7 7-7-7"/>
    </svg>
  </button>
  <div class="absolute right-0 mt-2 w-56 bg-white dark:bg-gray-800 rounded-lg shadow-lg border border-gray-200 dark:border-gray-700 py-1 z-10"
       role="menu">
    <a href="#" class="block px-4 py-2 text-sm text-gray-700 dark:text-gray-300 hover:bg-gray-100 dark:hover:bg-gray-700" role="menuitem">Edit</a>
    <a href="#" class="block px-4 py-2 text-sm text-gray-700 dark:text-gray-300 hover:bg-gray-100 dark:hover:bg-gray-700" role="menuitem">Duplicate</a>
    <div class="border-t border-gray-200 dark:border-gray-700 my-1"></div>
    <a href="#" class="block px-4 py-2 text-sm text-red-600 dark:text-red-400 hover:bg-gray-100 dark:hover:bg-gray-700" role="menuitem">Delete</a>
  </div>
</div>
```

### Dropdown with Dividers and Icons

```html
<div class="absolute right-0 mt-2 w-56 bg-white dark:bg-gray-800 rounded-lg shadow-lg border border-gray-200 dark:border-gray-700 py-1 z-10" role="menu">
  <a href="#" class="flex items-center gap-3 px-4 py-2 text-sm text-gray-700 dark:text-gray-300 hover:bg-gray-100 dark:hover:bg-gray-700" role="menuitem">
    <svg class="w-4 h-4 text-gray-400" fill="none" stroke="currentColor" viewBox="0 0 24 24" aria-hidden="true">
      <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M11 5H6a2 2 0 00-2 2v11a2 2 0 002 2h11a2 2 0 002-2v-5m-1.414-9.414a2 2 0 112.828 2.828L11.828 15H9v-2.828l8.586-8.586z"/>
    </svg>
    Edit
  </a>
  <a href="#" class="flex items-center gap-3 px-4 py-2 text-sm text-gray-700 dark:text-gray-300 hover:bg-gray-100 dark:hover:bg-gray-700" role="menuitem">
    <svg class="w-4 h-4 text-gray-400" fill="none" stroke="currentColor" viewBox="0 0 24 24" aria-hidden="true">
      <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M8 16H6a2 2 0 01-2-2V6a2 2 0 012-2h8a2 2 0 012 2v2m-6 12h8a2 2 0 002-2v-8a2 2 0 00-2-2h-8a2 2 0 00-2 2v8a2 2 0 002 2z"/>
    </svg>
    Duplicate
  </a>
  <div class="border-t border-gray-200 dark:border-gray-700 my-1"></div>
  <a href="#" class="flex items-center gap-3 px-4 py-2 text-sm text-red-600 dark:text-red-400 hover:bg-red-50 dark:hover:bg-red-900/20" role="menuitem">
    <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24" aria-hidden="true">
      <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M19 7l-.867 12.142A2 2 0 0116.138 21H7.862a2 2 0 01-1.995-1.858L5 7m5 4v6m4-6v6m1-10V4a1 1 0 00-1-1h-4a1 1 0 00-1 1v3M4 7h16"/>
    </svg>
    Delete
  </a>
</div>
```

## Tooltips

### CSS-Only Tooltip

```html
<div class="relative group inline-block">
  <button class="px-3 py-1.5 text-sm bg-gray-200 dark:bg-gray-700 text-gray-700 dark:text-gray-300 rounded-lg">
    Hover me
  </button>
  <div class="absolute bottom-full left-1/2 -translate-x-1/2 mb-2 px-3 py-1.5
              bg-gray-900 dark:bg-gray-700 text-white text-xs rounded-lg
              opacity-0 group-hover:opacity-100 transition-opacity duration-200
              pointer-events-none whitespace-nowrap"
       role="tooltip">
    Tooltip text here
    <div class="absolute top-full left-1/2 -translate-x-1/2 border-4 border-transparent border-t-gray-900 dark:border-t-gray-700"></div>
  </div>
</div>
```

## Skeleton Loaders

### Text Skeleton

```html
<div class="animate-pulse space-y-3">
  <div class="h-4 bg-gray-200 dark:bg-gray-700 rounded w-3/4"></div>
  <div class="h-4 bg-gray-200 dark:bg-gray-700 rounded w-full"></div>
  <div class="h-4 bg-gray-200 dark:bg-gray-700 rounded w-5/6"></div>
  <div class="h-4 bg-gray-200 dark:bg-gray-700 rounded w-1/2"></div>
</div>
```

### Image Skeleton

```html
<div class="animate-pulse">
  <div class="w-full h-48 bg-gray-200 dark:bg-gray-700 rounded-lg flex items-center justify-center">
    <svg class="w-10 h-10 text-gray-300 dark:text-gray-600" fill="currentColor" viewBox="0 0 20 20" aria-hidden="true">
      <path fill-rule="evenodd" d="M4 3a2 2 0 00-2 2v10a2 2 0 002 2h12a2 2 0 002-2V5a2 2 0 00-2-2H4zm12 12H4l4-8 3 6 2-4 3 6z" clip-rule="evenodd"/>
    </svg>
  </div>
</div>
```

### Card Skeleton

```html
<div class="bg-white dark:bg-gray-800 rounded-lg shadow-md p-6 animate-pulse">
  <div class="w-full h-40 bg-gray-200 dark:bg-gray-700 rounded-lg mb-4"></div>
  <div class="h-5 bg-gray-200 dark:bg-gray-700 rounded w-2/3 mb-3"></div>
  <div class="space-y-2">
    <div class="h-3 bg-gray-200 dark:bg-gray-700 rounded w-full"></div>
    <div class="h-3 bg-gray-200 dark:bg-gray-700 rounded w-4/5"></div>
  </div>
  <div class="flex items-center gap-3 mt-4">
    <div class="w-8 h-8 bg-gray-200 dark:bg-gray-700 rounded-full"></div>
    <div class="h-3 bg-gray-200 dark:bg-gray-700 rounded w-24"></div>
  </div>
</div>
```

## Accessibility Patterns

### Focus-Visible Rings

```html
<!-- Keyboard-only focus ring (no ring on mouse click) -->
<button class="px-4 py-2 bg-blue-600 text-white rounded-lg
               focus:outline-none focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-blue-600">
  Keyboard Focus Only
</button>

<!-- Custom focus ring for dark backgrounds -->
<a href="#" class="text-white focus-visible:outline-2 focus-visible:outline-offset-4 focus-visible:outline-white rounded">
  Link on dark background
</a>
```

### Screen Reader Only Text

```html
<!-- Visually hidden but read by screen readers -->
<button aria-label="Close">
  <svg class="w-5 h-5" aria-hidden="true"><!-- icon --></svg>
  <span class="sr-only">Close dialog</span>
</button>

<!-- Skip to main content link -->
<a href="#main-content"
   class="sr-only focus:not-sr-only focus:absolute focus:top-4 focus:left-4
          focus:z-50 focus:px-4 focus:py-2 focus:bg-blue-600 focus:text-white focus:rounded-lg">
  Skip to main content
</a>
```

### ARIA Attributes with Tailwind

```html
<!-- aria-expanded toggle indicator -->
<button class="flex items-center gap-2" aria-expanded="false">
  Menu
  <svg class="w-4 h-4 transition-transform aria-expanded:rotate-180" aria-hidden="true"
       fill="none" stroke="currentColor" viewBox="0 0 24 24">
    <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M19 9l-7 7-7-7"/>
  </svg>
</button>

<!-- aria-selected for tab panels -->
<button role="tab" aria-selected="true"
  class="px-4 py-2 aria-selected:bg-blue-600 aria-selected:text-white rounded-lg">
  Selected Tab
</button>

<!-- aria-current for navigation -->
<a href="#" aria-current="page"
   class="text-gray-600 aria-[current=page]:text-blue-600 aria-[current=page]:font-bold">
  Current Page
</a>
```

### Reduced Motion

```html
<!-- Disable animations for users who prefer reduced motion -->
<div class="animate-bounce motion-reduce:animate-none">
  Bouncing content (static for reduced-motion users)
</div>

<!-- Only animate for users who haven't set a preference -->
<div class="motion-safe:animate-pulse">
  Pulses only when safe
</div>

<!-- Disable transitions globally -->
<div class="transition-transform hover:scale-105 motion-reduce:transition-none motion-reduce:hover:scale-100">
  Scales on hover (but not for reduced-motion users)
</div>
```
