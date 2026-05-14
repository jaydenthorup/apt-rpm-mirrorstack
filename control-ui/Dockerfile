FROM python:3.12-alpine

WORKDIR /app

RUN apk add --no-cache docker-cli

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app.py .
COPY static ./static

EXPOSE 8088

CMD ["python", "app.py"]
