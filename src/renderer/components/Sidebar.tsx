import { Search, Plus, Settings, FileText, Brain } from 'lucide-react';
import { Note } from '../../shared/types';

interface SidebarProps {
  notes: Note[];
  activeNoteId?: string;
  searchQuery: string;
  onSearch: (query: string) => void;
  onSelectNote: (note: Note) => void;
  onCreateNote: () => void;
  onOpenSettings: () => void;
  onOpenReview: () => void;
  reviewDue: number;
  reviewActive: boolean;
}

function formatDate(dateString: string): string {
  const date = new Date(dateString);
  const now = new Date();
  const diff = now.getTime() - date.getTime();
  const days = Math.floor(diff / (1000 * 60 * 60 * 24));

  if (days === 0) {
    return 'Today';
  } else if (days === 1) {
    return 'Yesterday';
  } else if (days < 7) {
    return `${days} days ago`;
  } else {
    return date.toLocaleDateString('en-US', {
      month: 'short',
      day: 'numeric',
      year: date.getFullYear() !== now.getFullYear() ? 'numeric' : undefined,
    });
  }
}

function extractPreview(content: string): string {
  // Strip HTML and get first 100 chars
  const stripped = content.replace(/<[^>]*>/g, ' ').replace(/\s+/g, ' ').trim();
  return stripped.substring(0, 80) || 'No content';
}

function Sidebar({
  notes,
  activeNoteId,
  searchQuery,
  onSearch,
  onSelectNote,
  onCreateNote,
  onOpenSettings,
  onOpenReview,
  reviewDue,
  reviewActive,
}: SidebarProps) {
  return (
    <div className="sidebar">
      <div className="sidebar-header">
        <div className="sidebar-title">
          <FileText size={24} />
          Noschen
        </div>
        <div className="search-wrapper">
          <Search size={16} />
          <input
            type="text"
            className="search-input"
            placeholder="Search notes..."
            value={searchQuery}
            onChange={(e) => onSearch(e.target.value)}
          />
        </div>
        <button className="new-note-btn" onClick={onCreateNote}>
          <Plus size={16} />
          New Note
        </button>
      </div>
      <div className="note-list">
        {notes.length === 0 ? (
          <div style={{ padding: '20px', textAlign: 'center', color: 'var(--text-muted)' }}>
            {searchQuery ? 'No notes found' : 'No notes yet'}
          </div>
        ) : (
          notes.map((note) => (
            <div
              key={note.id}
              className={`note-item ${activeNoteId === note.id ? 'active' : ''}`}
              onClick={() => onSelectNote(note)}
            >
              <div className="note-item-title">{note.title || 'Untitled Note'}</div>
              <div className="note-item-date">{formatDate(note.updatedAt)}</div>
              <div className="note-item-preview">{extractPreview(note.content)}</div>
            </div>
          ))
        )}
      </div>
      <div className="sidebar-footer">
        <button
          className={`editor-header-btn ${reviewActive ? 'active' : ''}`}
          style={{ width: '100%', justifyContent: 'center', marginBottom: '8px' }}
          onClick={onOpenReview}
          title="Recall your own research — spaced review"
        >
          <Brain size={14} />
          Review
          {reviewDue > 0 && <span className="review-due-badge">{reviewDue}</span>}
        </button>
        <button
          className="editor-header-btn"
          style={{ width: '100%', justifyContent: 'center' }}
          onClick={onOpenSettings}
        >
          <Settings size={14} />
          AI Settings
        </button>
      </div>
    </div>
  );
}

export default Sidebar;
