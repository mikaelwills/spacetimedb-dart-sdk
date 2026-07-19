use spacetimedb::{
    procedure, reducer, table, view, AnonymousViewContext, ProcedureContext, Query,
    ReducerContext, ScheduleAt, Table, SpacetimeType,
};

/// Status enum for testing sum types
#[derive(SpacetimeType, Debug, Clone, PartialEq, Eq)]
pub enum NoteStatus {
    Draft,
    Published { published_at: u64 },
    Archived,
}

/// Simple Note table for testing
#[table(accessor = note, public)]
pub struct Note {
    #[primary_key]
    pub id: u32,
    pub title: String,
    pub content: String,
    #[index(btree)]
    pub timestamp: u64,
    pub status: NoteStatus,
}

/// Folder table with String primary key (for testing String PK delete events)
#[table(accessor = folder, public)]
pub struct Folder {
    #[primary_key]
    pub path: String,
    pub name: String,
    pub created_at: u64,
}

/// Reducer to create a new note
#[reducer]
pub fn create_note(ctx: &ReducerContext, title: String, content: String) {
    // Find the maximum ID and add 1 to ensure uniqueness
    let max_id = ctx.db.note()
        .iter()
        .map(|note| note.id)
        .max()
        .unwrap_or(0);

    let id = max_id + 1;
    let timestamp = 0;

    ctx.db.note().insert(Note {
        id,
        title,
        content,
        timestamp,
        status: NoteStatus::Draft,
    });
}

#[reducer]
pub fn update_note(ctx: &ReducerContext, note_id: u32, title: String, content: String) {
    if let Some(mut note) = ctx.db.note().id().find(note_id) {
        note.title = title;
        note.content = content;
        note.timestamp = 0;
        ctx.db.note().id().update(note);
    }
}

#[reducer]
pub fn update_note_guarded(ctx: &ReducerContext, note_id: u32, content: String) -> Result<(), String> {
    let Some(mut note) = ctx.db.note().id().find(note_id) else {
        return Err("no such note".into());
    };
    if note.content.starts_with("LOCKED") {
        return Err("note is locked".into());
    }
    note.content = content;
    note.timestamp = 0;
    ctx.db.note().id().update(note);
    Ok(())
}

#[reducer]
pub fn delete_note(ctx: &ReducerContext, note_id: u32) {
    ctx.db.note().id().delete(note_id);
}

/// Delete all notes in a single transaction (for testing multi-delete streams)
#[reducer]
pub fn delete_all_notes(ctx: &ReducerContext) {
    // Collect all note IDs first (can't iterate while modifying)
    let note_ids: Vec<u32> = ctx.db.note().iter().map(|n| n.id).collect();

    // Delete each note
    for id in note_ids {
        ctx.db.note().id().delete(id);
    }
}

/// Create a new folder (for testing String primary key)
#[reducer]
pub fn create_folder(ctx: &ReducerContext, path: String, name: String) {
    ctx.db.folder().insert(Folder {
        path,
        name,
        created_at: 0,
    });
}

/// Delete a folder by path (String primary key)
#[reducer]
pub fn delete_folder(ctx: &ReducerContext, path: String) {
    ctx.db.folder().path().delete(path);
}

/// Delete all folders in a single transaction
#[reducer]
pub fn delete_all_folders(ctx: &ReducerContext) {
    let paths: Vec<String> = ctx.db.folder().iter().map(|f| f.path.clone()).collect();
    for path in paths {
        ctx.db.folder().path().delete(path);
    }
}

/// Insert `count` notes in one transaction. Used by reactive-invariant tests
/// to verify that N-row transactions fire `rows` and `lastBatch` exactly once.
#[reducer]
pub fn create_notes_bulk(ctx: &ReducerContext, count: u32, title_prefix: String) {
    let max_id = ctx.db.note().iter().map(|note| note.id).max().unwrap_or(0);
    for i in 0..count {
        ctx.db.note().insert(Note {
            id: max_id + 1 + i,
            title: format!("{}-{}", title_prefix, i),
            content: format!("bulk content {}", i),
            timestamp: 0,
            status: NoteStatus::Draft,
        });
    }
}

/// Update every existing note's content in one transaction.
#[reducer]
pub fn update_all_notes(ctx: &ReducerContext, new_content: String) {
    let ids: Vec<u32> = ctx.db.note().iter().map(|n| n.id).collect();
    for id in ids {
        if let Some(mut note) = ctx.db.note().id().find(id) {
            note.content = new_content.clone();
            ctx.db.note().id().update(note);
        }
    }
}

/// Insert `inserts` new notes, update `updates` existing ones, and delete
/// `deletes` existing ones — all in a single transaction. Used to verify
/// that mixed-kind transactions still fire exactly once and carry the
/// correct event breakdown.
///
/// Assumes at least `updates + deletes` notes already exist.
#[reducer]
pub fn mixed_note_batch(
    ctx: &ReducerContext,
    inserts: u32,
    updates: u32,
    deletes: u32,
    marker: String,
) {
    let existing: Vec<u32> = ctx.db.note().iter().map(|n| n.id).collect();

    for (i, id) in existing.iter().take(updates as usize).enumerate() {
        if let Some(mut note) = ctx.db.note().id().find(*id) {
            note.content = format!("{}-updated-{}", marker, i);
            ctx.db.note().id().update(note);
        }
    }

    for id in existing.iter().skip(updates as usize).take(deletes as usize) {
        ctx.db.note().id().delete(*id);
    }

    let max_id = ctx.db.note().iter().map(|n| n.id).max().unwrap_or(0);
    for i in 0..inserts {
        ctx.db.note().insert(Note {
            id: max_id + 1 + i,
            title: format!("{}-inserted-{}", marker, i),
            content: format!("{}-inserted-content-{}", marker, i),
            timestamp: 0,
            status: NoteStatus::Draft,
        });
    }
}

/// A no-op reducer that commits without touching any rows. Used to verify
/// that empty transactions do not fire `lastBatch`.
#[reducer]
pub fn no_op(_ctx: &ReducerContext) {}

/// Diagnostic: inserts 5 hardcoded notes, no args. Used during the
/// reactive-invariants-tests bring-up to isolate whether the timeout we saw
/// on `create_notes_bulk` was an arg-encoding issue vs a reducer-registration
/// issue. If this succeeds and `create_notes_bulk` fails, it's args.
#[reducer]
pub fn diag_insert_five(ctx: &ReducerContext) {
    let max_id = ctx.db.note().iter().map(|n| n.id).max().unwrap_or(0);
    for i in 0..5u32 {
        ctx.db.note().insert(Note {
            id: max_id + 1 + i,
            title: format!("diag-{}", i),
            content: String::from("diag"),
            timestamp: 0,
            status: NoteStatus::Draft,
        });
    }
}

/// Reducer that returns `Err(message)` — exercises the v2 `Failed(Bytes)`
/// outcome on `ReducerResult`. The error message round-trips through
/// `errorBytes` → `errorMessage` getter on the Dart side.
#[reducer]
pub fn reducer_returns_err(_ctx: &ReducerContext, message: String) -> Result<(), String> {
    Err(message)
}

/// Reducer that panics at runtime — exercises the v2 `InternalError(str)`
/// outcome on `ReducerResult`. Distinct from `Failed`: the server constructs
/// the message text from the panic, not the reducer body.
#[reducer]
pub fn reducer_that_panics(_ctx: &ReducerContext) {
    panic!("intentional reducer panic");
}

/// Procedure that adds two numbers. Used by message_types_test's ProcedureResult
/// test to exercise the successful-return path of the procedure wire protocol.
#[procedure]
pub fn add_numbers(_ctx: &mut ProcedureContext, a: u32, b: u32) -> u32 {
    a + b
}

/// Procedure that panics at runtime. Used by error_handling_test's "Procedure
/// panic" test to exercise the internalError path. The panic message must
/// contain "divide" so the test's error-message substring check passes.
#[procedure]
pub fn divide_by_zero(_ctx: &mut ProcedureContext, numerator: u32) -> u32 {
    let divisor = if numerator > 0 { 0 } else { 1 };
    numerator / divisor
}

/// View to get all notes
/// Uses the btree-indexed timestamp column to iterate all rows
#[view(accessor = all_notes, public)]
pub fn all_notes(ctx: &AnonymousViewContext) -> Vec<Note> {
    // Use the timestamp btree index with a range filter to get all notes
    ctx.db.note().timestamp().filter(0u64..).collect()
}

/// View to get first note (returns Option<Note>)
#[view(accessor = first_note, public)]
pub fn first_note(ctx: &AnonymousViewContext) -> Option<Note> {
    // Use the id index to find the first note
    ctx.db.note().id().find(1)
}

/// Query-builder view returning all notes via impl Query<Note>
#[view(accessor = notes_query_all, public)]
pub fn notes_query_all(ctx: &AnonymousViewContext) -> impl Query<Note> {
    ctx.from.note().build()
}

#[table(accessor = tagged_item, public)]
pub struct TaggedItem {
    #[primary_key]
    pub id: u32,
    pub name: String,
    pub tag_ids: Vec<u64>,
    pub labels: Vec<String>,
}

#[reducer]
pub fn create_tagged_item(
    ctx: &ReducerContext,
    id: u32,
    name: String,
    tag_ids: Vec<u64>,
    labels: Vec<String>,
) {
    ctx.db.tagged_item().insert(TaggedItem {
        id,
        name,
        tag_ids,
        labels,
    });
}

/// Table exercising `Option<T>` columns for codegen-option-support round-trip.
#[table(accessor = optional_item, public)]
pub struct OptionalItem {
    #[primary_key]
    pub id: u32,
    pub nickname: Option<String>,
    pub score: Option<u64>,
    pub resolved_at: Option<u64>,
}

#[reducer]
pub fn create_optional_item(
    ctx: &ReducerContext,
    id: u32,
    nickname: Option<String>,
    score: Option<u64>,
    resolved_at: Option<u64>,
) {
    ctx.db.optional_item().insert(OptionalItem {
        id,
        nickname,
        score,
        resolved_at,
    });
}

#[table(accessor = entity, public)]
pub struct Entity {
    #[primary_key]
    pub id: u64,
    pub x: f32,
    pub y: f32,
    pub z: f32,
    pub health: u32,
}

#[reducer]
pub fn bulk_insert_entities(ctx: &ReducerContext, count: u32) {
    let max_id = ctx.db.entity().iter().map(|e| e.id).max().unwrap_or(0);
    for i in 0..count as u64 {
        ctx.db.entity().insert(Entity {
            id: max_id + 1 + i,
            x: i as f32 * 0.1,
            y: i as f32 * 0.2,
            z: i as f32 * 0.3,
            health: 100,
        });
    }
}

#[reducer]
pub fn mutate_random_entities(ctx: &ReducerContext, count: u32, seed: u64) {
    let ids: Vec<u64> = ctx.db.entity().iter().map(|e| e.id).collect();
    if ids.is_empty() {
        return;
    }
    let len = ids.len() as u64;
    let mut rng = seed;
    for _ in 0..count {
        rng = rng.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
        let idx = (rng >> 33) % len;
        let target_id = ids[idx as usize];
        if let Some(mut e) = ctx.db.entity().id().find(target_id) {
            e.x += 1.0;
            e.y += 1.0;
            e.z += 1.0;
            e.health = e.health.wrapping_add(1);
            ctx.db.entity().id().update(e);
        }
    }
}

#[table(accessor = scheduled_task, public, scheduled(run_scheduled_task))]
pub struct ScheduledTask {
    #[primary_key]
    #[auto_inc]
    pub scheduled_id: u64,
    pub scheduled_at: ScheduleAt,
    pub label: String,
}

#[reducer]
pub fn run_scheduled_task(_ctx: &ReducerContext, _task: ScheduledTask) {}

#[table(accessor = cadence_item, public)]
pub struct CadenceItem {
    #[primary_key]
    pub id: u32,
    pub cadence: ScheduleAt,
    pub label: String,
}

#[reducer]
pub fn create_cadence_item(ctx: &ReducerContext, id: u32, cadence: ScheduleAt, label: String) {
    ctx.db.cadence_item().insert(CadenceItem { id, cadence, label });
}

/// Standalone `SpacetimeType` product type (NOT a table) — exercises
/// product-type class generation. Used as a reducer param below so it also
/// appears as a `RefType` in reducers.dart (product-ref encode path).
#[derive(SpacetimeType, Debug, Clone, PartialEq)]
pub struct ServerPosition {
    pub x: f32,
    pub y: f32,
}

#[reducer]
pub fn move_to(ctx: &ReducerContext, id: u64, position: ServerPosition) {
    if let Some(mut e) = ctx.db.entity().id().find(id) {
        e.x = position.x;
        e.y = position.y;
        ctx.db.entity().id().update(e);
    }
}

/// Single-field table — exercises the `Object.hash` single-arg codegen path.
#[table(accessor = single_field, public)]
pub struct SingleField {
    #[primary_key]
    pub id: u32,
}

#[reducer]
pub fn create_single_field(ctx: &ReducerContext, id: u32) {
    ctx.db.single_field().insert(SingleField { id });
}

/// Initialize with some test data
#[reducer(init)]
pub fn init(ctx: &ReducerContext) {
    ctx.db.note().insert(Note {
        id: 1,
        title: "First Note".to_string(),
        content: "This is my first note".to_string(),
        timestamp: 0,
        status: NoteStatus::Draft,
    });

    ctx.db.note().insert(Note {
        id: 2,
        title: "Second Note".to_string(),
        content: "This is my second note".to_string(),
        timestamp: 0,
        status: NoteStatus::Published { published_at: 1234567890 },
    });
}
