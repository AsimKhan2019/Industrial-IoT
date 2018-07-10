# this is a copy of docker/linux/amd64/Dockerfile to support building on dockerhub
ARG runtime_base_tag=2.1-runtime-alpine
ARG build_base_tag=2.1-sdk-alpine

FROM microsoft/dotnet:${build_base_tag} AS build
WORKDIR /app

# copy csproj and restore as distinct layers
COPY opcpublisher/*.csproj ./opcpublisher/
WORKDIR /app/opcpublisher
RUN dotnet restore

# copy and publish app
WORKDIR /app
COPY opcpublisher/. ./opcpublisher/
WORKDIR /app/opcpublisher
RUN dotnet publish -c Release -o out
RUN ls /app/opcpublisher/out

# start it up
FROM microsoft/dotnet:${runtime_base_tag} AS runtime
# Add an unprivileged user account for running the module
RUN adduser -Ds /bin/sh moduleuser 
USER moduleuser
WORKDIR /app
COPY --from=build /app/opcpublisher/out ./
ENTRYPOINT ["dotnet", "opcpublisher.dll"]