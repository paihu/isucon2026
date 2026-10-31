# frozen_string_literal: true

require 'stringio'
require 'zip'

module Isureal
  class App
    def export_posts_handler
      author = current_user
      user_id = author.id
      posts = db.select(<<~SQL, user_id)
        SELECT #{POST_COLUMNS}
        FROM posts p
        JOIN posting_windows w ON w.id = p.posting_window_id
        WHERE p.author_id = $1 AND p.deleted_at IS NULL
        ORDER BY p.posted_at, p.id
      SQL
      images = posts.to_h { |row| [row[:image_id], ImageCache.read(row[:image_id])] }
      missing = images.select { |_, data| data.nil? }.keys
      unless missing.empty?
        db.select('SELECT id, data, origin FROM image_objects WHERE id = ANY($1::text[])', missing).each do |row|
          data = row[:data].empty? ? row[:origin] && ImageOrigin.fetch(row[:origin], row[:id]) : row[:data]
          next if data.nil?

          images[row[:id]] = data
          ImageCache.write(row[:id], data)
        end
      end
      # image_objects との JOIN（パーティションを ID で総当たりして遅い）の代わりに、画像の無い投稿をここで除く。
      posts = posts.select { |row| images[row[:image_id]] }

      archive = Zip::OutputStream.write_buffer(StringIO.new) do |writer|
        items = posts.each_with_index.map do |row, index|
          image_path = format('images/%06d.jpg', index + 1)
          writer.put_next_entry(image_path, '', Zip::ExtraField.new, Zip::Entry::STORED)
          writer.write(images.fetch(row[:image_id]))
          post_response(Post.from_row(row), author).merge(imagePath: image_path)
        end
        writer.put_next_entry('posts.json')
        writer.write(Response.encode_json(items))
      end
      headers['content-disposition'] = 'attachment; filename="isureal-posts.zip"'
      headers['cache-control'] = 'no-store'
      blob(200, 'application/zip', archive.string)
    end
  end
end
