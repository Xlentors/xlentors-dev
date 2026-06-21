# xlentors-dev — Personal Portfolio

## Local development

```bash
# 1. Create and activate a virtual environment
python3 -m venv venv
source venv/bin/activate

# 2. Install dependencies
pip install -r requirements.txt

# 3. Copy the example env file and fill in your values
cp .env.example .env

# 4. Run the dev server
python app.py
```

The app will be available at http://localhost:5000.

## Deploy to Cloud Run

```bash
# Build and push the container image, then deploy
gcloud run deploy xlentors-dev \
  --source . \
  --region us-central1 \
  --allow-unauthenticated \
  --port 8080
```

You will be prompted to enable the Cloud Run and Artifact Registry APIs on first run if they are not already enabled.
