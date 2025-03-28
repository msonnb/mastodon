# frozen_string_literal: true

class Settings::BlueskyCrossPostingController < Settings::BaseController
  def show; end

  def update
    if current_user.update(user_params)
      I18n.locale = current_user.locale
      redirect_to settings_bluesky_cross_posting_path, notice: I18n.t('generic.changes_saved_msg')
    else
      render :show
    end
  end

  private

  def user_params
    params.expect(user: [:bluesky_cross_posting_enabled])
  end
end
