import { i18n } from '@lingui/core';
import { I18nProvider } from '@lingui/react';
import { LoadingOverlay, Text, useDirection } from '@mantine/core';
import { type JSX, useEffect, useState } from 'react';

import { useStoredTableState } from '@lib/states/StoredTableState';
import { useShallow } from 'zustand/react/shallow';
import { api } from '../App';
import { markLocaleReady } from '../functions/localeReady';
import { useLocalState } from '../states/LocalState';
import { useServerApiState } from '../states/ServerApiState';
import { fetchGlobalStates } from '../states/states';

export const defaultLocale = 'en';

const initialDocumentLocale =
  typeof document === 'undefined' ? null : document.documentElement.lang;

const rtlLocales = new Set(['ar', 'fa', 'he']);

/*
 * Function which returns a record of supported languages.
 * Note that this is not a constant, as it is used in the LanguageSelect component
 */
export const getSupportedLanguages = (): Record<string, string> => {
  return {
    ar: 'العربية',
    bg: 'Български',
    cs: 'Čeština',
    da: 'Dansk',
    de: 'Deutsch',
    el: 'Ελληνικά',
    en: 'English',
    es: 'Español',
    es_MX: 'Español (México)',
    et: 'Eesti',
    fa: 'فارسی',
    fi: 'Suomi',
    fr: 'Français',
    he: 'עברית',
    hi: 'हिन्दी',
    hu: 'Magyar',
    it: 'Italiano',
    ja: '日本語',
    ko: '한국어',
    lt: 'Lietuvių',
    lv: 'Latviešu',
    nl: 'Nederlands',
    no: 'Norsk',
    pl: 'Polski',
    pt: 'Português',
    pt_BR: 'Português (Brasil)',
    ro: 'Română',
    ru: 'Русский',
    sk: 'Slovenčina',
    sl: 'Slovenščina',
    sr: 'Српски',
    sv: 'Svenska',
    th: 'ไทย',
    tr: 'Türkçe',
    uk: 'Українська',
    vi: 'Tiếng Việt',
    zh_Hans: '中文（简体）',
    zh_Hant: '中文（繁體）'
  };
};

function getSupportedLocale(locale: string | null | undefined): string | null {
  if (!locale) {
    return null;
  }

  const normalizedLocale = locale.replaceAll('_', '-').toLowerCase();
  const supportedLocales = Object.keys(getSupportedLanguages());

  const exactMatch = supportedLocales.find(
    (supportedLocale) =>
      supportedLocale.replaceAll('_', '-').toLowerCase() === normalizedLocale
  );

  if (exactMatch) {
    return exactMatch;
  }

  const baseLocale = normalizedLocale.split('-')[0];
  return (
    supportedLocales.find(
      (supportedLocale) => supportedLocale === baseLocale
    ) ?? null
  );
}

export function getLocaleDirection(locale: string | null): 'ltr' | 'rtl' {
  const activeLocale = locale || getPriorityLocale();
  const baseLocale = activeLocale.split(/[-_]/)[0].toLowerCase();

  return rtlLocales.has(baseLocale) ? 'rtl' : 'ltr';
}

export function LanguageContext({
  children
}: Readonly<{ children: JSX.Element }>) {
  const [language] = useLocalState(useShallow((state) => [state.language]));
  const [server] = useServerApiState(useShallow((state) => [state.server]));
  const { setDirection } = useDirection();

  const [loadedState, setLoadedState] = useState<
    'loading' | 'loaded' | 'error'
  >('loading');

  useEffect(() => {
    let isActive = true;
    const lang = getPriorityLocale();

    document.documentElement.lang = lang.replaceAll('_', '-');
    setDirection(getLocaleDirection(lang));

    activateLocale(lang)
      .then(() => {
        if (isActive) setLoadedState('loaded');

        /*
         * Configure the default Accept-Language header for all requests.
         * - Locally selected locale
         * - Server default locale
         * - en-us (backup)
         */
        const locales = [lang, server.default_locale, 'en-us']
          .filter(
            (locale): locale is string => !!locale && locale !== 'pseudo-LOCALE'
          )
          .map((locale) => locale.replaceAll('_', '-').toLowerCase());

        const new_locales = [...new Set(locales)].join(', ');

        if (new_locales == api.defaults.headers.common['Accept-Language']) {
          return;
        }

        // Update default Accept-Language headers
        api.defaults.headers.common['Accept-Language'] = new_locales;

        // Reload server state (and refresh status codes). Forced: the
        // Accept-Language header actually changed (initial set, or a real
        // locale change), so this must not be skipped by the "already
        // fetched" guard even if another caller already fetched once.
        fetchGlobalStates(true);

        // Clear out cached table column names
        useStoredTableState.getState().clearTableColumnNames();
      })
      /* istanbul ignore next */
      .catch((err) => {
        console.error('ERR: Failed loading translations', err);
        if (isActive) setLoadedState('error');
      });

    return () => {
      isActive = false;
    };
  }, [language, server.default_locale, setDirection]);

  if (loadedState === 'loading') {
    return <LoadingOverlay visible={true} />;
  }

  /* istanbul ignore next */
  if (loadedState === 'error') {
    return (
      <Text>
        An error occurred while loading translations, see browser console for
        details.
      </Text>
    );
  }

  // only render the i18n Provider if the locales are fully activated, otherwise we end
  // up with an error in the browser console
  return <I18nProvider i18n={i18n}>{children}</I18nProvider>;
}

// This function is used to determine the locale to activate based on the prioritization rules.
export function getPriorityLocale(): string {
  const serverDefault = useServerApiState.getState().server.default_locale;
  const userDefault = useLocalState.getState().language;

  for (const locale of [
    userDefault,
    serverDefault,
    initialDocumentLocale,
    defaultLocale
  ]) {
    const supportedLocale = getSupportedLocale(locale);

    if (supportedLocale) {
      return supportedLocale;
    }
  }

  return defaultLocale;
}

export async function activateLocale(locale: string | null) {
  if (!locale) {
    locale = getPriorityLocale();
  }

  const localeDir = locale.split('-')[0]; // Extract the base locale (e.g., 'en' from 'en-US')

  try {
    const { messages } = await import(`../locales/${localeDir}/messages.ts`);
    i18n.load(locale, messages);
    i18n.activate(locale);
    markLocaleReady();
  } catch (err) {
    console.error(`Failed to load locale ${locale}:`, err);
  }
}
