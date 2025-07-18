# Use multi-platform support - this will use the native architecture when possible
FROM ruby:2.5.7

# Install dependency packages
RUN apt-get update && apt-get install -y \
  curl \
  fonts-liberation \
  libappindicator3-1 \
  libasound2 \
  libatk-bridge2.0-0 \
  libatk1.0-0 \
  libatspi2.0-0 \
  libcups2 \
  libdbus-1-3 \
  libgbm1 \
  libgtk-3-0 \
  libnspr4 \
  libnss3 \
  libx11-xcb1 \
  libxcomposite1 \
  libxcursor1 \
  libxdamage1 \
  libxfixes3 \
  libxi6 \
  libxrandr2 \
  libxss1 \
  libxtst6 \
  nodejs \
  xdg-utils \
  libvulkan1 \
  libu2f-udev

# Install Chrome - use architecture-appropriate package
RUN ARCH=$(dpkg --print-architecture) \
    && if [ "$ARCH" = "amd64" ]; then \
         wget --quiet https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb \
         && dpkg -i google-chrome-stable_current_amd64.deb; \
       elif [ "$ARCH" = "arm64" ]; then \
         wget --quiet https://dl.google.com/linux/direct/google-chrome-stable_current_arm64.deb \
         && dpkg -i google-chrome-stable_current_arm64.deb; \
       else \
         echo "Unsupported architecture: $ARCH"; exit 1; \
       fi \
    && apt-get -f install \
    && rm -f /google-chrome-stable_current_*.deb

# Install Yarn
ENV PATH=/root/.yarn/bin:$PATH
RUN touch ~/.bashrc && \
    curl -o- -L https://yarnpkg.com/install.sh | sh

# Setup project home directory
RUN mkdir /app
WORKDIR /app

# Add Gemfile and cache results of bundle install
COPY .ruby-version grpc-web.gemspec Gemfile Gemfile.lock /app/
COPY lib/grpc_web/version.rb /app/lib/grpc_web/

RUN gem install bundler -v 2.3.26 \
 && bundle config --global frozen 1 \
 && bundle install -j4 --retry 3 \
 # Remove unneeded files (cached *.gem, *.o, *.c)
 && rm -rf /usr/local/bundle/cache/*.gem
