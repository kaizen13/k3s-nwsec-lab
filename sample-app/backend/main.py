from contextlib import asynccontextmanager
from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
import asyncpg
import os
import logging

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

DB_URL = (
    f"postgresql://{os.getenv('POSTGRES_USER')}:"
    f"{os.getenv('POSTGRES_PASSWORD')}@"
    f"demo-postgres.data.svc.cluster.local:5432/"
    f"{os.getenv('POSTGRES_DB')}"
)

pool: asyncpg.Pool = None


@asynccontextmanager
async def lifespan(app: FastAPI):
    global pool
    pool = await asyncpg.create_pool(DB_URL, min_size=2, max_size=10)
    logger.info("Database connection pool created")
    yield
    await pool.close()
    logger.info("Database connection pool closed")


app = FastAPI(title="K8s Security Lab - Todo API", version="1.0.0", lifespan=lifespan)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
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
        async with pool.acquire() as conn:
            rows = await conn.fetch("SELECT * FROM todos ORDER BY created_at DESC")
        return [dict(row) for row in rows]
    except Exception as e:
        logger.error(f"DB error: {e}")
        raise HTTPException(status_code=503, detail="Database unavailable")


@app.post("/api/todos", status_code=201)
async def create_todo(todo: Todo):
    try:
        async with pool.acquire() as conn:
            row = await conn.fetchrow(
                "INSERT INTO todos (title, completed) VALUES ($1, $2) RETURNING *",
                todo.title, todo.completed
            )
        return dict(row)
    except Exception as e:
        logger.error(f"DB error: {e}")
        raise HTTPException(status_code=503, detail="Database unavailable")


@app.patch("/api/todos/{todo_id}")
async def update_todo(todo_id: int, update: TodoUpdate):
    try:
        async with pool.acquire() as conn:
            row = await conn.fetchrow(
                "UPDATE todos SET completed=$1 WHERE id=$2 RETURNING *",
                update.completed, todo_id
            )
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
        async with pool.acquire() as conn:
            await conn.execute("DELETE FROM todos WHERE id=$1", todo_id)
        return {"message": "deleted", "id": todo_id}
    except Exception as e:
        logger.error(f"DB error: {e}")
        raise HTTPException(status_code=503, detail="Database unavailable")
