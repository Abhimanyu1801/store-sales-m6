import os
import sys
import json
import time
import asyncio
from fastapi.concurrency import run_in_threadpool
from typing import List

from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse
from pydantic import BaseModel

from src.pipelines.prediction_pipeline import PredictionPipeline

app = FastAPI()

VERSION = os.getenv("APP_VERSION", "dev")

# Files prediction_pipeline.py loads at request time (see the M2 fix log)
REQUIRED_ARTIFACTS = [
    "artifacts/trained_model.joblib",
    "artifacts/oil_model.joblib",
    "artifacts/covariates.joblib",
    "artifacts/timeseries_data.joblib",
]


def log_json(level, message, **fields):
    """One JSON object per line on stdout. Container Insights ships it to Log Analytics."""
    record = {
        "ts": time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime()) + "Z",
        "level": level,
        "msg": message,
        "version": VERSION,
    }
    record.update(fields)
    print(json.dumps(record), flush=True)


@app.middleware("http")
async def access_log(request: Request, call_next):
    start = time.perf_counter()
    status = 500  # stays 500 if the handler raises
    try:
        response = await call_next(request)
        status = response.status_code
        return response
    finally:
        path = request.url.path
        # Skip successful probe noise; every other request, and every 5xx, is logged.
        if not (path in ("/healthz", "/readyz") and status < 500):
            log_json(
                "error" if status >= 500 else "info",
                "request",
                method=request.method,
                path=path,
                status=status,
                duration_ms=round((time.perf_counter() - start) * 1000, 1),
            )


class Covariate_params(BaseModel):
    store_nbr: int
    family: str
    horizon: int
    onpromotion: List[int]
    is_holiday: List[int]


@app.get("/healthz")
async def liveness():
    """Liveness: the process is up and can answer HTTP. No dependency checks."""
    return {"status": "alive"}


@app.get("/version")
async def version():
    """Which build is serving traffic (used to verify a rollback)."""
    return {"version": VERSION}


@app.get("/debug/error")
async def controlled_error(token: str = ""):
    """Controlled HTTP 500 for the monitoring demo. Needs the demo token."""
    if token != os.getenv("DEBUG_TOKEN", "") or not os.getenv("DEBUG_TOKEN"):
        return JSONResponse(status_code=404, content={"detail": "Not Found"})
    return JSONResponse(status_code=500, content={"error": "controlled test error"})


def check_database():
    """Run SELECT 1 using the team's state module (Key Vault + managed identity)."""
    from state import get_conn
    conn = get_conn()
    try:
        cur = conn.cursor()
        cur.execute("SELECT 1")
        cur.fetchone()
    finally:
        conn.close()


@app.get("/readyz")
def readiness():
    """Readiness: model artifacts exist AND the database is reachable."""
    if os.getenv("BREAK_READY", "false").lower() == "true":
        return JSONResponse(status_code=503,
                            content={"status": "not ready", "reason": "BREAK_READY demo flag"})
    missing = [p for p in REQUIRED_ARTIFACTS if not os.path.exists(p)]
    if missing:
        return JSONResponse(status_code=503,
                            content={"status": "not ready", "missing_artifacts": missing})
    try:
        check_database()
    except Exception as e:
        return JSONResponse(status_code=503,
                            content={"status": "not ready", "database": str(e)[:200]})
    return {"status": "ready", "model": "loaded", "database": "ok"}


# One forecast at a time per pod: each forecast loads the model into memory,
# so running many in parallel OOM-kills the pod. Extra requests wait in line,
# and the HPA adds pods when CPU rises. The event loop stays free, so
# /healthz still answers instantly while a forecast is running.
FORECAST_SLOTS = asyncio.Semaphore(int(os.getenv("FORECAST_CONCURRENCY", "1")))


def _run_forecast(params):
    pipeline_obj = PredictionPipeline()
    return pipeline_obj.produce_forecasts(
        store_nbr=params.store_nbr,
        family=params.family,
        horizon=params.horizon,
        onpromotion=params.onpromotion,
        is_holiday=params.is_holiday,
    )


@app.post("/")
async def get_forecasts(params: Covariate_params):
    async with FORECAST_SLOTS:
        return await run_in_threadpool(_run_forecast, params)
