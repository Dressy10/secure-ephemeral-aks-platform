FROM golang:1.23-alpine AS build
WORKDIR /src
COPY go.mod .
COPY main.go .
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /ledger .

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /ledger /ledger
USER 65532:65532
EXPOSE 8080
ENTRYPOINT ["/ledger"]
