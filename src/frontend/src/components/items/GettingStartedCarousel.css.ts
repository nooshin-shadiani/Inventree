import { rem } from '@mantine/core';
import { globalStyle, style } from '@vanilla-extract/css';

import { vars } from '../../theme';

export const carousel = style({});

// Mantine Carousel does not expose its built-in English slide-status text.
// Hide that live region so the localized one rendered by our wrapper is used.
globalStyle(`${carousel} > [role='status']`, {
  display: 'none'
});

export const card = style({
  height: rem(170),
  display: 'flex',
  flexDirection: 'column',
  justifyContent: 'space-between',
  alignItems: 'flex-start',
  backgroundSize: 'cover',
  backgroundPosition: 'center'
});

export const title = style({
  fontWeight: 900,
  lineHeight: 1.2,
  fontSize: rem(32),
  marginTop: 0,
  [vars.lightSelector]: { color: vars.colors.dark[5] },
  [vars.darkSelector]: { color: vars.colors.white[0] }
});

export const category = style({
  opacity: 0.7,
  fontWeight: 700,
  [vars.lightSelector]: { color: vars.colors.dark[5] },
  [vars.darkSelector]: { color: vars.colors.white[0] }
});
