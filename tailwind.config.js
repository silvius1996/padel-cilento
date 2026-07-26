/* =========================================================
   PADEL CILENTO — configurazione Tailwind
   Questa e' la stessa configurazione che prima stava dentro
   index.html, quando Tailwind veniva caricato dal CDN.
   Il foglio di stile si rigenera con:  npm run build:css
========================================================= */
module.exports = {
  content: ['./public/**/*.html'],
  theme: {
    extend: {
      colors: {
        lime: { neon: '#C6FF3D' },
        electric: { DEFAULT: '#3D7FFF' },
        court: {
          900: '#0B0F0E',
          800: '#111613',
          700: '#171D19',
          600: '#222A25',
          500: '#333D36',
        },
      },
      fontFamily: {
        display: ['"Space Grotesk"', 'sans-serif'],
        body: ['Inter', 'sans-serif'],
      },
      boxShadow: {
        'neon': '0 0 0 1px rgba(198,255,61,0.4), 0 0 24px -4px rgba(198,255,61,0.35)',
        'neon-sm': '0 0 0 1px rgba(198,255,61,0.5)',
      },
      animation: {
        'pulse-slot': 'pulseSlot 1.8s ease-in-out infinite',
      },
      keyframes: {
        pulseSlot: {
          '0%, 100%': { opacity: 1 },
          '50%': { opacity: 0.35 },
        },
      },
    },
  },
};
