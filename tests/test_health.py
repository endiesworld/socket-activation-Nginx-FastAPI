from fastapi.testclient import TestClient
from app.main import app

def test_health():
    client = TestClient(app)
    resp = client.get("/health")
    resp_json = resp.json()
    
    assert resp.status_code == 200
    assert resp_json['status'] == "ok"