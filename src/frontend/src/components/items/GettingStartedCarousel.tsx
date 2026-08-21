import { Trans, useLingui } from '@lingui/react/macro';
import { Carousel } from '@mantine/carousel';
import { Anchor, Button, Paper, Text, VisuallyHidden } from '@mantine/core';
import type { EmblaCarouselType } from 'embla-carousel';
import { useEffect, useState } from 'react';

import { StylishText } from '@lib/components/StylishText';
import * as classes from './GettingStartedCarousel.css';
import type { MenuLinkItem } from './MenuLinks';

function StartedCard({ title, description, link }: Readonly<MenuLinkItem>) {
  return (
    <Paper shadow='md' p='xl' radius='md' className={classes.card}>
      <div>
        <StylishText size='md'>{title}</StylishText>
        <Text size='sm' className={classes.category} lineClamp={2}>
          {description}
        </Text>
      </div>
      <Anchor href={link} target='_blank'>
        <Button>
          <Trans>Read More</Trans>
        </Button>
      </Anchor>
    </Paper>
  );
}

export function GettingStartedCarousel({
  items
}: Readonly<{
  items: MenuLinkItem[];
}>) {
  const { t } = useLingui();
  const [emblaApi, setEmblaApi] = useState<EmblaCarouselType | null>(null);
  const [selectedSlide, setSelectedSlide] = useState(0);
  const [slideCount, setSlideCount] = useState(0);

  useEffect(() => {
    if (!emblaApi) {
      return;
    }

    const updateSlideStatus = () => {
      setSelectedSlide(emblaApi.selectedScrollSnap());
      setSlideCount(emblaApi.scrollSnapList().length);
    };

    updateSlideStatus();
    emblaApi.on('select', updateSlideStatus);
    emblaApi.on('reInit', updateSlideStatus);

    return () => {
      emblaApi.off('select', updateSlideStatus);
      emblaApi.off('reInit', updateSlideStatus);
    };
  }, [emblaApi]);

  const slides = items.map((item) => (
    <Carousel.Slide key={item.id}>
      <StartedCard {...item} />
    </Carousel.Slide>
  ));

  const currentSlide = selectedSlide + 1;

  return (
    <>
      <VisuallyHidden role='status' aria-live='polite' aria-atomic='true'>
        {slideCount > 0 && t`Slide ${currentSlide} of ${slideCount}`}
      </VisuallyHidden>
      <Carousel
        className={classes.carousel}
        getEmblaApi={setEmblaApi}
        slideSize={{ base: '100%', sm: '50%', md: '33.333333%' }}
        slideGap={{ base: 0, sm: 'md' }}
        emblaOptions={{
          loop: true,
          slidesToScroll: 3
        }}
      >
        {slides}
      </Carousel>
    </>
  );
}
