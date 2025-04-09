# Use the official Python image as the base
FROM python:3.9-slim

# Set the working directory in the container
WORKDIR /app

# Copy the requirements file into the container
COPY requirements.txt .

# Install the dependencies
RUN pip install --no-cache-dir Flask==3.0.3 flask-cors==4.0.0 requests==2.31.0 gunicorn==22.0.0

# Copy the rest of the application code into the container
COPY . .

# Expose the port the application runs on
EXPOSE 5000

# Command to run the application with Gunicorn
CMD ["gunicorn", "--bind", "0.0.0.0:5000", "app:app", "--workers", "4", "--threads", "2"]

