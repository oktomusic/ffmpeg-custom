# syntax=docker/dockerfile:1
# check=error=true

# We have to ignore some dockerfile-utils errors, because `--unpack` is currently unsupported for the `ADD` instruction
# - https://github.com/microsoft/vscode-containers/issues/297
# - https://github.com/rcjsuen/dockerfile-utils/issues/131
# 
# When updating tarball versions, update the checksums as well:
# - curl -fsSL TARBALL_URL | sha256sum

FROM --platform=$BUILDPLATFORM tonistiigi/xx AS xx

FROM --platform=$BUILDPLATFORM alpine:3.22 AS builder

LABEL org.opencontainers.image.title="Oktomusic Custom FFmpeg"
LABEL org.opencontainers.image.description="Custom build of FFmpeg for Oktomusic project"
LABEL org.opencontainers.image.authors="AFCMS <afcm.contact@gmail.com>"
LABEL org.opencontainers.image.licenses="LGPL-2.1-only"
LABEL org.opencontainers.image.source="https://github.com/oktomusic/ffmpeg-custom"
LABEL io.artifacthub.package.readme-url="https://raw.githubusercontent.com/oktomusic/ffmpeg-custom/refs/heads/master/README.md"
LABEL io.artifacthub.package.category="skip-prediction"
LABEL io.artifacthub.package.keywords="music,media,tool"
LABEL io.artifacthub.package.license="LGPL-2.1-only"
LABEL io.artifacthub.package.maintainers='[{"name":"AFCMS","email":"afcm.contact@gmail.com"}]'

COPY --from=xx / /

# ---------------------------
# Install build dependencies
# ---------------------------
RUN apk add --no-cache \
    clang \
    lld \
    llvm-dev \
    build-base \
    pkgconfig \
    yasm \
    nasm \
    bash \
    autoconf \
    automake \
    libtool

ARG TARGETPLATFORM
RUN xx-info env

RUN xx-apk add --no-cache \
    musl-dev \
    gcc \
    g++ \
    zlib-dev \
    libogg-dev

WORKDIR /usr/local/src

# ---------------------------
# Build Opus statically from official tarball
# ---------------------------
ENV OPUS_VERSION=1.5.2
ENV OPUS_CHECKSUM=sha256:65c1d2f78b9f2fb20082c38cbe47c951ad5839345876e46941612ee87f9a7ce1
# dockerfile-utils: ignore
ADD --unpack=true \
    --checksum=${OPUS_CHECKSUM} \
    https://github.com/xiph/opus/releases/download/v${OPUS_VERSION}/opus-${OPUS_VERSION}.tar.gz \
    /usr/local/src/
WORKDIR /usr/local/src/opus-${OPUS_VERSION}
RUN CC=xx-clang ./configure \
    --host=$(xx-clang --print-target-triple) \
    --disable-shared \
    --enable-static \
    --prefix=$(xx-info sysroot)usr/local \
    && make -j$(nproc) \
    && make install

# ---------------------------
# Build FLAC statically from official tarball
# ---------------------------
WORKDIR /usr/local/src

ENV FLAC_VERSION=1.5.0
ENV FLAC_CHECKSUM=sha256:f2c1c76592a82ffff8413ba3c4a1299b6c7ab06c734dee03fd88630485c2b920
# dockerfile-utils: ignore
ADD --unpack=true \
    --checksum=${FLAC_CHECKSUM} \
    https://github.com/xiph/flac/releases/download/${FLAC_VERSION}/flac-${FLAC_VERSION}.tar.xz \
    /usr/local/src/

WORKDIR /usr/local/src/flac-${FLAC_VERSION}
RUN CC=xx-clang ./configure \
    --host=$(xx-clang --print-target-triple) \
    --disable-shared \
    --enable-static \
    --prefix=$(xx-info sysroot)usr/local \
    LDFLAGS="-static" \
    && make -j$(nproc) AM_LDFLAGS="-all-static" \
    && make install \
    && cp src/metaflac/metaflac /usr/local/bin/metaflac

# ---------------------------
# Build FFmpeg statically with Opus and FLAC support
# ---------------------------
WORKDIR /usr/local/src

ENV FFMPEG_VERSION=8.0.1
ENV FFMPEG_CHECKSUM=sha256:05ee0b03119b45c0bdb4df654b96802e909e0a752f72e4fe3794f487229e5a41
# dockerfile-utils: ignore
ADD --unpack=true \
    --checksum=${FFMPEG_CHECKSUM} \
    https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VERSION}.tar.xz \
    /usr/local/src/

# Configure FFmpeg static build
WORKDIR /usr/local/src/ffmpeg-${FFMPEG_VERSION}
RUN xx-clang --setup-target-triple && \
    export PKG_CONFIG_PATH=$(xx-info sysroot)usr/local/lib/pkgconfig && \
    export PKG_CONFIG_LIBDIR=$(xx-info sysroot)usr/local/lib/pkgconfig && \
    ./configure \
    --prefix=/usr/local \
    --extra-version=oktomusic \
    --enable-cross-compile \
    --cross-prefix=$(xx-clang --print-target-triple)- \
    --arch=$(xx-info arch) \
    --target-os=linux \
    --cc=xx-clang \
    --cxx=xx-clang++ \
    --pkg-config-flags="--static" \
    --extra-cflags="-static" \
    --extra-ldflags="-static" \
    --disable-everything \
    # Build configuration
    --disable-shared \
    --enable-static \
    --disable-doc \
    --disable-debug \
    # Tools
    --disable-ffplay \
    --enable-ffprobe \
    # External libraries
    --enable-libopus \
    # Codecs (encoders/decoders)
    --enable-encoder=flac \
    --enable-decoder=flac \
    --enable-encoder=libopus \
    --enable-decoder=libopus \
    --enable-decoder=mjpeg \
    --enable-decoder=png \
    # Formats (muxers/demuxers)
    --enable-muxer=flac \
    --enable-demuxer=flac \
    --enable-muxer=opus \
    --enable-demuxer=opus \
    --enable-muxer=image2 \
    # Filters
    --enable-filter=aresample \
    --enable-filter=aformat \
    --enable-filter=anull \
    # Protocols
    --enable-protocol=file \
    # Subsystems/features
    --disable-avdevice \
    --disable-network \
    --disable-bsfs \
    --disable-iconv \
    --disable-vaapi \
    --disable-vdpau \
    --enable-swresample \
    --disable-swscale

RUN make -j$(nproc) && make install && make clean

RUN xx-verify --static /usr/local/bin/ffmpeg
RUN xx-verify --static /usr/local/bin/ffprobe
RUN xx-verify --static /usr/local/bin/metaflac

# ---------------------------
# Create minimal runtime image
# ---------------------------
FROM alpine:3.22 AS runtime

COPY --from=builder /usr/local/bin/ffmpeg /usr/local/bin/ffmpeg
COPY --from=builder /usr/local/bin/ffprobe /usr/local/bin/ffprobe
COPY --from=builder /usr/local/bin/metaflac /usr/local/bin/metaflac

ENTRYPOINT ["/usr/local/bin/ffmpeg"]