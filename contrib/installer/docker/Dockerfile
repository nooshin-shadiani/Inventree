ARG INVENTREE_BASE_SOURCE=inventree/inventree@sha256:7e4c96a1987a8b308d3f157a7c3a03435993457400361eceadfb156530a3e415
FROM ${INVENTREE_BASE_SOURCE}

ARG PLUGIN_ARCHIVE_SHA256
ARG PLUGIN_ARCHIVE_SUBDIRECTORY
ARG PLUGIN_VERSION
ARG STOCK_PLUGIN_ARCHIVE_SUBDIRECTORY
ARG STOCK_PLUGIN_VERSION

COPY cache/plugin-source.tar.gz /tmp/plugin-source.tar.gz

# All runtime dependencies are already pinned in the InvenTree image. Avoid
# build isolation and dependency resolution so this layer never accesses PyPI.
# The currency plugin installs a Python startup hook because InvenTree validates
# configured currency codes before loading external plugin entry points.
RUN echo "${PLUGIN_ARCHIVE_SHA256}  /tmp/plugin-source.tar.gz" | sha256sum --check --strict - \
    && python -m pip install \
        --disable-pip-version-check \
        --no-build-isolation \
        --no-deps \
        "file:///tmp/plugin-source.tar.gz#subdirectory=${PLUGIN_ARCHIVE_SUBDIRECTORY}" \
    && python -m pip install \
        --disable-pip-version-check \
        --no-build-isolation \
        --no-deps \
        "file:///tmp/plugin-source.tar.gz#subdirectory=${STOCK_PLUGIN_ARCHIVE_SUBDIRECTORY}" \
    && python -c 'from moneyed import CURRENCIES; assert "IRT" in CURRENCIES' \
    && test "$(python -c 'import importlib.metadata; print(importlib.metadata.version("inventree-usd-irt-exchange-rate"))')" = "${PLUGIN_VERSION}" \
    && test "$(python -c 'import importlib.metadata; print(importlib.metadata.version("inventree-stock-xlsx-adjustment"))')" = "${STOCK_PLUGIN_VERSION}" \
    && rm /tmp/plugin-source.tar.gz

LABEL org.opencontainers.image.title="InvenTree with USD/IRT and stock XLSX plugins" \
      org.opencontainers.image.source="https://github.com/nooshin-shadiani/Inventree" \
      org.opencontainers.image.version="currency-${PLUGIN_VERSION}-stock-${STOCK_PLUGIN_VERSION}"
