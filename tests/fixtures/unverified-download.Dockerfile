FROM debian
RUN curl -fsSLo /tmp/x.tgz https://example.com/x.tgz \
    && tar xzf /tmp/x.tgz
