FROM python:3.11-slim

# Install unixODBC and Microsoft ODBC Driver 18 for SQL Server
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        gnupg2 \
        curl \
        apt-transport-https \
        unixodbc-dev \
 && curl -fsSL https://packages.microsoft.com/keys/microsoft.asc \
        | gpg --dearmor -o /usr/share/keyrings/microsoft-prod.gpg \
 && curl -fsSL https://packages.microsoft.com/config/debian/12/prod.list \
        > /etc/apt/sources.list.d/mssql-release.list \
 && apt-get update \
 && ACCEPT_EULA=Y apt-get install -y --no-install-recommends msodbcsql18 \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY sync.py .

CMD ["python", "sync.py"]
