FROM python:3.12-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY relay.py .

EXPOSE 3001

# Use gunicorn in production instead of Flask dev server
CMD ["gunicorn", "--bind", "0.0.0.0:3001", "--workers", "2", "--timeout", "30", "relay:app"]
