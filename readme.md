# My Photography Website (Hugo)

This is a static photography website built using [Hugo](https://gohugo.io/).  
Posts are organized as photo stories, with responsive images and optional narrative text.  
The site is designed for fast, static deployment (e.g. S3, GitHub Pages, Netlify).

---

## 🚀 Getting Started

### 1. Install Hugo (Extended version)
You’ll need the **extended** version of Hugo to use image processing:

---

## 📝 How to Create a New Post

1. **Run this command:**

```bash
hugo new posts/$(date +%F)_my-post-title/index.md
```

Or:
```bash
./content/new-post.sh 2024-12-24_St-Lucia
```

## 📝 How to Add Images to a Post

Place the images in the assets post directory, e.g. assets/originals/2024-12-24_St-Lucia

1. **Run this command:**

```bash
./content/add-images.sh content/posts/2024-12-24_St-Lucia
```