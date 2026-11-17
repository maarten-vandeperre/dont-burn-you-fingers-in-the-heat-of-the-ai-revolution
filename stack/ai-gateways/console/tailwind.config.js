/** @type {import('tailwindcss').Config} */
export default {
  content: ['./index.html', './src/**/*.{js,jsx}'],
  theme: {
    extend: {
      fontFamily: {
        sans: ['"Red Hat Text"', 'ui-sans-serif', 'system-ui', 'sans-serif'],
        display: ['"Red Hat Display"', 'ui-sans-serif', 'system-ui', 'sans-serif'],
        mono: ['"Red Hat Mono"', 'ui-monospace', 'SFMono-Regular', 'monospace'],
      },
      colors: {
        brand: { 50: '#fef2f2', 100: '#fde3e3', 500: '#ee0000', 600: '#cc0000', 700: '#a60000' },
      },
    },
  },
  plugins: [],
}
