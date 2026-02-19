from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
import asyncpg
import os
import logging

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

app = FastAPI(title="K8s Security Lab - Todo API", version="1.0.0")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

DB_URL = (
    f"postgresql://{os.getenv('POSTGRES_USER')}:"
    f"{os.getenv('POSTGRES_PASSWORD')}@"
    f"demo-postgres.data.svc.cluster.local:5432/"
    f"{os.getenv('POSTGRES_DB')}"
)


class Todo(BaseModel):
    title: str
    completed: bool = False


class TodoUpdate(BaseModel):
    completed: bool


@app.get("/health")
async def health():
    return {"status": "healthy", "service": "demo-backend"}


@app.get("/api/todos")
async def get_todos():
    try:
        conn = await asyncpg.connect(DB_URL)
        rows = await conn.fetch("SELECT * FROM todos ORDER BY created_at DESC")
        await conn.close()
        return [dict(row) for row in rows]
    except Exception as e:
        logger.error(f"DB error: {e}")
        raise HTTPException(status_code=503, detail="Database unavailable")


@app.post("/api/todos", status_code=201)
async def create_todo(todo: Todo):
    try:
        conn = await asyncpg.connect(DB_URL)
        row = await conn.fetchrow(
            "INSERT INTO todos (title, completed) VALUES ($1, $2) RETURNING *",
            todo.title, todo.completed
        )
        await conn.close()
        return dict(row)
    except Exception as e:
        logger.error(f"DB error: {e}")
        raise HTTPException(status_code=503, detail="Database unavailable")


@app.patch("/api/todos/{todo_id}")
async def update_todo(todo_id: int, update: TodoUpdate):
    try:
        conn = await asyncpg.connect(DB_URL)
        row = await conn.fetchrow(
            "UPDATE todos SET completed=$1 WHERE id=$2 RETURNING *",
            update.completed, todo_id
        )
        await conn.close()
        if not row:
            raise HTTPException(status_code=404, detail="Todo not found")
        return dict(row)
    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"DB error: {e}")
        raise HTTPException(status_code=503, detail="Database unavailable")


@app.delete("/api/todos/{todo_id}")
async def delete_todo(todo_id: int):
    try:
        conn = await asyncpg.connect(DB_URL)
        await conn.execute("DELETE FROM todos WHERE id=$1", todo_id)
        await conn.close()
        return {"message": "deleted", "id": todo_id}
    except Exception as e:
        logger.error(f"DB error: {e}")
        raise HTTPException(status_code=503, detail="Database unavailable")
