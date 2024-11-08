# base stage
FROM ubuntu:24.04 AS base
USER root

ARG ARCH=amd64
ENV LIGHTEN=0

WORKDIR /ragflow

RUN rm -f /etc/apt/apt.conf.d/docker-clean \
    && echo 'Binary::apt::APT::Keep-Downloaded-Packages "true";' > /etc/apt/apt.conf.d/keep-cache

RUN --mount=type=cache,id=ragflow_base_apt,target=/var/cache/apt,sharing=locked \
    apt update && apt-get --no-install-recommends install -y ca-certificates

# If you download Python modules too slow, you can use a pip mirror site to speed up apt and poetry
RUN sed -i 's|http://archive.ubuntu.com|https://mirrors.tuna.tsinghua.edu.cn|g' /etc/apt/sources.list.d/ubuntu.sources

RUN --mount=type=cache,id=ragflow_base_apt,target=/var/cache/apt,sharing=locked \
    apt update && apt install -y curl libpython3-dev nginx libglib2.0-0 libglx-mesa0 pkg-config libicu-dev libgdiplus default-jdk python3-pip pipx \
    && rm -rf /var/lib/apt/lists/*

RUN pip3 config set global.index-url https://pypi.tuna.tsinghua.edu.cn/simple && pip3 config set global.trusted-host "pypi.tuna.tsinghua.edu.cn mirrors.pku.edu.cn" && pip3 config set global.extra-index-url "https://mirrors.pku.edu.cn/pypi/web/simple" \
    && pipx install poetry \
    && /root/.local/bin/poetry self add poetry-plugin-pypi-mirror

# https://forum.aspose.com/t/aspose-slides-for-net-no-usable-version-of-libssl-found-with-linux-server/271344/13
# aspose-slides on linux/arm64 is unavailable
RUN --mount=type=bind,source=libssl1.1_1.1.1f-1ubuntu2_amd64.deb,target=/root/libssl1.1_1.1.1f-1ubuntu2_amd64.deb \
    if [ "${ARCH}" = "amd64" ]; then \
        dpkg -i /root/libssl1.1_1.1.1f-1ubuntu2_amd64.deb; \
    fi

ENV PYTHONDONTWRITEBYTECODE=1 DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1
ENV PATH=/root/.local/bin:$PATH
# Configure Poetry
ENV POETRY_NO_INTERACTION=1
ENV POETRY_VIRTUALENVS_IN_PROJECT=true
ENV POETRY_VIRTUALENVS_CREATE=true
ENV POETRY_REQUESTS_TIMEOUT=15
ENV POETRY_PYPI_MIRROR_URL=https://pypi.tuna.tsinghua.edu.cn/simple/

# builder stage
FROM base AS builder
USER root

WORKDIR /ragflow

RUN --mount=type=cache,id=ragflow_builder_apt,target=/var/cache/apt,sharing=locked \
    apt update && apt install -y nodejs npm cargo && \
    rm -rf /var/lib/apt/lists/*

COPY web web
COPY docs docs
RUN --mount=type=cache,id=ragflow_builder_npm,target=/root/.npm,sharing=locked \
    cd web && npm i --force && npm run build

# install dependencies from poetry.lock file
COPY pyproject.toml poetry.toml poetry.lock ./

RUN --mount=type=cache,id=ragflow_builder_poetry,target=/root/.cache/pypoetry,sharing=locked \
    if [ "$LIGHTEN" -eq 0 ]; then \
        poetry install --no-root --with=full; \
    else \
        poetry install --no-root; \
    fi

# production stage
FROM base AS production
USER root

WORKDIR /ragflow

# Install necessary packages
RUN --mount=type=cache,id=ragflow_production_apt,target=/var/cache/apt,sharing=locked \
    apt update && apt install -y --no-install-recommends \
    nginx libgl1 vim less git wget && \
    rm -rf /var/lib/apt/lists/*

# Copy application files
COPY web web
COPY api api
COPY conf conf
COPY deepdoc deepdoc
COPY rag rag
COPY agent agent
COPY graphrag graphrag
COPY pyproject.toml poetry.toml poetry.lock ./
COPY docker/entrypoint.sh ./entrypoint.sh

# Copy the download_deps.py script
COPY download_deps.py .

# Install Python dependencies needed for download_deps.py
ENV VIRTUAL_ENV=/ragflow/.venv
ENV PATH="${VIRTUAL_ENV}/bin:${PATH}"

# Install Python dependencies
COPY --from=builder ${VIRTUAL_ENV} ${VIRTUAL_ENV}

# Run the download_deps.py script
RUN python3 download_deps.py

# Set the TIKA_SERVER_JAR environment variable
ENV TIKA_SERVER_JAR="file:///ragflow/tika-server-standard.jar"

# Copy nltk_data if it's required by the application
COPY nltk_data /root/nltk_data

# Copy compiled web pages from builder stage
COPY --from=builder /ragflow/web/dist /ragflow/web/dist

# Set permissions and entrypoint
RUN chmod +x ./entrypoint.sh

ENTRYPOINT ["./entrypoint.sh"]
